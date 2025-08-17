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
            echo "🔍 Обработка файла: $file"
    
    # Получаем исходную частоту дискретизации из файла
    original_rate=$(ffprobe -v error -select_streams a -show_entries stream=sample_rate \
                     -of default=noprint_wrappers=1:nokey=1 "$file")
    [ -z "$original_rate" ] && original_rate=44100
    
    # Анализ параметров громкости исходного файла (однопроход для получения базовых значений)
    analysis=$(ffmpeg -hide_banner -i "$file" -af loudnorm=print_format=summary -f null - 2>&1)
    input_lufs=$(echo "$analysis" | grep "Input Integrated" | awk '{print $3}')
    input_tp=$(echo "$analysis" | grep "Input True Peak" | awk '{print $4}' | sed 's/^\+//')
    
    # Получение битрейта исходного файла для MP3.
    # Для файлов M4A используем фиксированный битрейт 320k.
    if [[ "$file" == *.m4a ]]; then
        bitrate="320k"
    else
        bitrate=$(ffprobe -v error -select_streams a -show_entries stream=bit_rate \
                 -of default=noprint_wrappers=1:nokey=1 "$file")
        [ -z "$bitrate" ] && bitrate="320k"
    fi
    
    # Пропускаем MP3, если они уже соответствуют нормам
    if [[ "$file" == *.mp3 ]] && (( $(echo "$input_lufs >= -15.5" | bc -l) )) && \
       (( $(echo "$input_lufs <= -13.5" | bc -l) )) && (( $(echo "$input_tp <= -0.2" | bc -l) )); then
        echo "✅ MP3 уже соответствует нормам. Пропускаем: $file"
        return
    fi
    
    # Если M4A соответствует нормам, кодируем в MP3 с сохранением исходных LUFS, TP, LRA
    if [[ "$file" == *.m4a ]] && (( $(echo "$input_lufs >= -15.5" | bc -l) )) && \
       (( $(echo "$input_lufs <= -13.5" | bc -l) )) && (( $(echo "$input_tp <= -0.2" | bc -l) )); then
        echo "✅ M4A соответствует нормам, кодируем в MP3 320 CBR без изменения уровней."
        filter="volume=0dB"
    else
        # Обычная обработка через нормализацию
        # Вычисляем коррекцию (целевой уровень –14 LUFS)
        adjustment=$(echo "scale=2; -14 - ($input_lufs)" | bc)
        predicted_tp=$(echo "scale=2; $input_tp + $adjustment" | bc)

        # Если прогнозируемый TP > -0.2 dBTP, используем двухпроходное кодирование через loudnorm
        if (( $(echo "$predicted_tp > -0.2" | bc -l) )); then
            echo "⚠️ Высокий прогнозируемый TP ($predicted_tp dBTP), запускаем двухпроходное кодирование."
            
            json=$(ffmpeg -hide_banner -i "$file" -af "loudnorm=i=-15.5:lra=12:tp=-0.7:print_format=json" -f null - 2>&1)
            measured_I=$(echo "$json" | awk -F'"' '/"input_i"/ {print $4}')
            measured_TP=$(echo "$json" | awk -F'"' '/"input_tp"/ {print $4}')
            measured_LRA=$(echo "$json" | awk -F'"' '/"input_lra"/ {print $4}')
            measured_thresh=$(echo "$json" | awk -F'"' '/"input_thresh"/ {print $4}')
            offset=$(echo "$json" | awk -F'"' '/"target_offset"/ {print $4}')
            
            filter="loudnorm=i=-15.5:lra=12:tp=-0.7:measured_I=${measured_I}:measured_TP=${measured_TP}:measured_LRA=${measured_LRA}:measured_thresh=${measured_thresh}:offset=${offset}:linear=true:print_format=summary"
        else
            filter="volume=${adjustment}dB"
            echo "✅ TP в пределах нормы ($predicted_tp dBTP), используем volume (+${adjustment} dB)."
        fi
    fi

    # Формирование имени файла, добавляя суффикс _New.
    output_file="${file%.*}_New.mp3"
    if [ -e "$output_file" ]; then
        output_file="${file%.*}_New1.mp3"
    fi

    # Кодирование в MP3 320 CBR
    ffmpeg -y -hide_banner -i "$file" \
    -af "$filter" \
    -c:a libmp3lame -b:a "$bitrate" \
    -ar "$original_rate" \
    -write_xing 0 -id3v2_version 3 \
    -map_metadata 0 \
    "$output_file"

    # Проверяем успешность создания файла
    if [ ! -f "$output_file" ]; then
        echo "❌ Ошибка: Не удалось создать файл: $output_file" >&2
        echo "$file" >> error.log
    else
        echo "🎵 Создан новый файл: $output_file"
    fi
}

export -f process_file

# Рекурсивный поиск файлов и параллельная обработка
find . -type f \( -iname "*.mp3" -o -iname "*.m4a" \) -print0 | \
    parallel -0 -j16 --bar --eta process_file

# Вывод финального сообщения об ошибках, если таковые имеются
if [ -s error.log ]; then
    echo -e "\nОбработка завершена с ошибками. Файлы, для которых не удалось создать нормализованные копии:"
    cat error.log
else
    echo -e "\nОбработка всех файлов завершена успешно!"
fi
