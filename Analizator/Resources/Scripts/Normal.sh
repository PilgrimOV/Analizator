#!/bin/bash
# Поиск утилит из Homebrew/MacPorts
export PATH="/usr/local/bin:/opt/homebrew/bin:/opt/local/bin:$PATH"
shopt -s nullglob

# Если в аргументе передана папка — перейти в неё (на всякий случай)
if [ -n "$1" ]; then
  cd "$1" || exit 1
fi

# Удаляем лог ошибок, если он существует
rm -f error.log

process_file() {
    file="$1"
    echo "🔍🔍 Обработка файла: $file"
    
    # Исходная частота дискретизации
    original_rate=$(ffprobe -v error -select_streams a -show_entries stream=sample_rate \
                     -of default=noprint_wrappers=1:nokey=1 "$file")
    [ -z "$original_rate" ] && original_rate=44100
    
    # Анализ (однопроход) для базовых значений
    analysis=$(ffmpeg -hide_banner -i "$file" -af loudnorm=print_format=summary -f null - 2>&1)
    input_lufs=$(echo "$analysis" | grep "Input Integrated" | awk '{print $3}')
    input_tp=$(echo "$analysis" | grep "Input True Peak" | awk '{print $4}' | sed 's/^\+//')
    
    # Битрейт
    if [[ "$file" == *.m4a ]]; then
        bitrate="320k"
    else
        bitrate=$(ffprobe -v error -select_streams a -show_entries stream=bit_rate \
                 -of default=noprint_wrappers=1:nokey=1 "$file")
        [ -z "$bitrate" ] && bitrate="320k"
    fi
    
    # Пропускаем MP3, если уже в норме
    if [[ "$file" == *.mp3 ]] && (( $(echo "$input_lufs >= -15" | bc -l) )) && \
       (( $(echo "$input_lufs <= -13.5" | bc -l) )) && (( $(echo "$input_tp <= 0.0" | bc -l) )); then
        echo "✅✅ MP3 уже соответствует нормам. Пропускаем: $file"
        return
    fi
    
    # Если M4A в норме — просто кодируем в MP3 320 без изменения уровней
    if [[ "$file" == *.m4a ]] && (( $(echo "$input_lufs >= -15" | bc -l) )) && \
       (( $(echo "$input_lufs <= -13.5" | bc -l) )) && (( $(echo "$input_tp <= -0.4" | bc -l) )); then
        echo "✅ M4A соответствует нормам, кодируем в MP3 320 CBR без изменения уровней."
        filter="volume=0dB"
    else
        # === НОВАЯ ЛОГИКА ВЫБОРА ФИЛЬТРА ===
        # Цель 1: -14 LUFS
        adj_14=$(echo "scale=3; -14 - ($input_lufs)" | bc -l)
        predTP_14=$(echo "scale=3; $input_tp + $adj_14" | bc -l)
        
        # --- NEW (исправлено): TP-фикс вниз только для тихих/околотаргетных (adj_14 > 0) ---
tp_fix="-0.4"  # общий TP-порог
if (( $(echo "$adj_14 > 0" | bc -l) )) && (( $(echo "$input_tp > $tp_fix" | bc -l) )); then
    # Сколько dB нужно УМЕНЬШИТЬ, чтобы уложиться в TP-порог (получится отрицательное число)
    g_down=$(echo "scale=3; $tp_fix - ($input_tp)" | bc -l)
    I_after_down=$(echo "scale=3; $input_lufs + $g_down" | bc -l)

    if (( $(echo "$I_after_down >= -15.5" | bc -l) )); then
        echo "🟡 TP выше порога TP>${tp_fix} dBTP → линейно уменьшаем на ${g_down} dB → ≈ ${I_after_down} LUFS, TP ≈ ${tp_fix} dBTP."
        filter="volume=${g_down}dB"
    fi
fi
        
        # Если файл громче цели (-14) — понижаем линейно с учётом TP-порога
        if [ -z "$filter" ]; then
if (( $(echo "$adj_14 <= 0" | bc -l) )); then
    tp_thresh="-0.4"
    predTP_after_down14=$(echo "scale=3; $input_tp + $adj_14" | bc -l)

    if (( $(echo "$predTP_after_down14 > $tp_thresh" | bc -l) )); then
        # Сколько не хватает, чтобы уложиться в TP-порог
        extra_down=$(echo "scale=3; $predTP_after_down14 - ($tp_thresh)" | bc -l)
        new_adj=$(echo "scale=3; $adj_14 - $extra_down" | bc -l)
        echo "🟡 Снизить до -14 LUFS нельзя (прогноз $predTP_after_down14 dBTP) — снижаем ещё на $extra_down dB; итоговое уменьшение $new_adj dB."
        filter="volume=${new_adj}dB"
    else
        echo "✅ Снизили до -14 LUFS (${adj_14} dB), TP после = ${predTP_after_down14} dBTP."
        filter="volume=${adj_14}dB"
    fi

                # Файл тихий: пытаемся поднять линейно (максимально, не нарушая TP, в коридоре [-15.5; -14] LUFS)
        else
            tp_thresh="-0.4"  # твой порог для подъёма

            # Максимально допустимый линейный подъём по TP: input_tp + g <= tp_thresh
            gTPmax=$(echo "scale=3; $tp_thresh - ($input_tp)" | bc -l)

            if (( $(echo "$gTPmax <= 0" | bc -l) )); then
                # Вообще нельзя поднимать без нарушения TP → двухпроходный loudnorm
                echo "⚠️ Поднимать линейно нельзя (gTPmax=${gTPmax} dB, TP-порог ${tp_thresh} dBTP). Запускаем двухпроходный loudnorm."
                json=$(ffmpeg -hide_banner -i "$file" -af "loudnorm=i=-15:lra=12:tp=-0.7:print_format=json" -f null - 2>&1)
                measured_I=$(echo "$json" | awk -F'\"' '/\"input_i\"/ {print $4}')
                measured_TP=$(echo "$json" | awk -F'\"' '/\"input_tp\"/ {print $4}')
                measured_LRA=$(echo "$json" | awk -F'\"' '/\"input_lra\"/ {print $4}')
                measured_thresh=$(echo "$json" | awk -F'\"' '/\"input_thresh\"/ {print $4}')
                offset=$(echo "$json" | awk -F'\"' '/\"target_offset\"/ {print $4}')
                filter="loudnorm=i=-15:lra=12:tp=-0.7:measured_I=${measured_I}:measured_TP=${measured_TP}:measured_LRA=${measured_LRA}:measured_thresh=${measured_thresh}:offset=${offset}:linear=true:print_format=summary"
            else
                # g_lin = min(adj_14, gTPmax)
                # (adj_14 уже посчитан выше как -14 - input_lufs)
                if (( $(echo "$adj_14 <= $gTPmax" | bc -l) )); then
                    g_lin="$adj_14"
                else
                    g_lin="$gTPmax"
                fi

                # Предполагаемый итог по громкости при таком линейном подъёме
                I_lin=$(echo "scale=3; $input_lufs + $g_lin" | bc -l)
                TP_lin=$(echo "scale=3; $input_tp + $g_lin" | bc -l)

                # Принимаем линейный подъём, только если попадаем хотя бы в -15.5 LUFS
                if (( $(echo "$I_lin >= -15.5" | bc -l) )); then
                    echo "✅ Подняли на ${g_lin} dB: целевой ≈ ${I_lin} LUFS (максимально близко к -14), TP после ≈ ${TP_lin} dBTP."
                    filter="volume=${g_lin}dB"
                else
                    echo "⚠️ Даже максимально допустимый по TP подъём даёт лишь ${I_lin} LUFS (< -15.5). Запускаем двухпроходный loudnorm."
                    json=$(ffmpeg -hide_banner -i "$file" -af "loudnorm=i=-15:lra=12:tp=-0.7:print_format=json" -f null - 2>&1)
                    measured_I=$(echo "$json" | awk -F'\"' '/\"input_i\"/ {print $4}')
                    measured_TP=$(echo "$json" | awk -F'\"' '/\"input_tp\"/ {print $4}')
                    measured_LRA=$(echo "$json" | awk -F'\"' '/\"input_lra\"/ {print $4}')
                    measured_thresh=$(echo "$json" | awk -F'\"' '/\"input_thresh\"/ {print $4}')
                    offset=$(echo "$json" | awk -F'\"' '/\"target_offset\"/ {print $4}')
                    filter="loudnorm=i=-15:lra=12:tp=-0.7:measured_I=${measured_I}:measured_TP=${measured_TP}:measured_LRA=${measured_LRA}:measured_thresh=${measured_thresh}:offset=${offset}:linear=true:print_format=summary"
                fi
            fi
        fi
    fi

        # === КОНЕЦ НОВОЙ ЛОГИКИ ===
    fi

    # Имя выходного файла
    output_file="${file%.*}_New.mp3"
    if [ -e "$output_file" ]; then
        output_file="${file%.*}_New1.mp3"
    fi

    # Кодирование в MP3
    ffmpeg -y -hide_banner -i "$file" \
      -af "$filter" \
      -c:a libmp3lame -b:a "$bitrate" \
      -ar "$original_rate" \
      -write_xing 0 -id3v2_version 3 \
      -map_metadata 0 \
      "$output_file"

    # Проверка результата
    if [ ! -f "$output_file" ]; then
        echo "❌ Ошибка: Не удалось создать файл: $output_file" >&2
        echo "$file" >> error.log
    else
        echo "🗂️🗂️ СОЗДАН НОВЫЙ ФАЙЛ: $output_file"
    fi
}

export -f process_file

# Без рекурсии обрабатываем *.mp3 и *.m4a
parallel -j16 --bar --eta -k process_file ::: *.mp3 *.m4a

# Итог
if [ -s error.log ]; then
    echo "❌❌❌ Обработка завершена с ошибками. Эти файлы не удалось создать:"
    cat error.log
else
    echo "✅✅✅ Обработка всех файлов завершена успешно!"
fi
