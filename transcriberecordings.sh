#!/bin/bash
# Transcribes one or more .m4a audio files and creates a .lrc file with the same name
# Uses openai-whisper whisper for transcoding.
# Can be played in an audio player like Musicolet, which shows the lyrics in sync with the audio.
# uses "uv" Python environment manager, installed with "curl -LsSf https://astral.sh/uv/install.sh | sh"
# Can be used on a directory, or group of files, Examples:
# transcriberecordings.sh ./dir/
# transcriberecordings.sh ./dir/file*.m4a
#
if [ -z "$1" ]; then
	echo "Usage: $0 <directory|file|wildcard> ..."
	exit 1
fi

shopt -s nullglob
# Force script and all children to only use Cores 0, 1, 2, and 3 (to avoid bogging down the whole machine)
taskset -cp 0-3 $$ >/dev/null 2>&1

# 1. Argument Parsing
declare -a m4a_files_to_check

for arg in "$@"; do
	arg="${arg%/}"
	
	if [ -d "$arg" ]; then
		for f in "$arg"/*.m4a; do
			[[ -e "$f" ]] && m4a_files_to_check+=("$f")
		done
	elif [ -f "$arg" ]; then
		if [[ "$arg" == *.m4a ]]; then
			m4a_files_to_check+=("$arg")
		else
			echo "Skipping non-m4a file: $arg"
		fi
	else
		echo "Warning: '$arg' is not a valid file or directory."
	fi
done

if [ ${#m4a_files_to_check[@]} -eq 0 ]; then
	echo "No .m4a files found to process."
	exit 0
fi

# 2. Pre-Scan Phase
total_files=0
total_bytes=0
declare -a files_to_process
declare -A existing_lrc
declare -A dir_scanned

echo "Scanning directories and calculating workload..."

for file in "${m4a_files_to_check[@]}"; do
	dir_name=$(dirname "$file")
	lrc_file="${file%.m4a}.lrc"
	
	if [[ -z "${dir_scanned["$dir_name"]}" ]]; then
		for lrc in "$dir_name"/*.lrc; do
			[[ -e "$lrc" ]] && existing_lrc["$lrc"]=1
		done
		dir_scanned["$dir_name"]=1
	fi
	
	if [[ -z "${existing_lrc["$lrc_file"]}" ]] || [ ! -s "$lrc_file" ]; then
		files_to_process+=("$file")
		size=$(stat -c%s "$file")
		total_bytes=$((total_bytes + size))
		((total_files++))
	fi
done

if [ "$total_files" -eq 0 ]; then
	echo "All specified files are already transcribed."
	exit 0
fi

echo "Found $total_files file(s) to process. Total size: $((total_bytes / 1048576)) MB."

# 3. Tracking Variables
processed_files=0
processed_bytes=0
start_time=$(date +%s)
last_completed_time=$start_time

# 4. Execution Loop
for file in "${files_to_process[@]}"; do
	((processed_files++))
	file_size=$(stat -c%s "$file")
	file_dir=$(dirname "$file")
	vtt_file="${file%.m4a}.vtt"
	lrc_file="${file%.m4a}.lrc"
	
	if [ "$processed_bytes" -gt 0 ]; then
		elapsed=$((last_completed_time - start_time))
		if [ "$elapsed" -eq 0 ]; then elapsed=1; fi 
		bytes_per_sec=$((processed_bytes / elapsed))
		remaining_bytes=$((total_bytes - processed_bytes))
		eta_secs=$((remaining_bytes / bytes_per_sec))
		eta_str=$(printf "%02d:%02d:%02d" $((eta_secs / 3600)) $(((eta_secs % 3600) / 60)) $((eta_secs % 60)))
	else
		eta_str="Calculating..."
	fi

	# NEW: Verbose startup message so the terminal doesn't hang in silence
	printf "\r\e[K  -> [File %d of %d] [ETA: %s] | Loading audio and initializing Whisper..." "$processed_files" "$total_files" "$eta_str"

	uvx --from openai-whisper whisper "$file" --model base --output_dir "$file_dir" --output_format vtt 2>&1 | while read -r line; do
		if [[ "$line" == "["* ]]; then
			timestamp="${line%%]*}]"
			printf "\r\e[K  -> [File %d of %d] [ETA: %s] | Position: %s" "$processed_files" "$total_files" "$eta_str" "$timestamp"
		fi
	done
	echo ""

	if [ -f "$vtt_file" ]; then
		> "$lrc_file"
		current_time=""
		
		while IFS= read -r line; do
			line="${line%$'\r'}"
			
			if [[ "$line" == *"-->"* ]]; then
				# FIXED: Changed variable to 'vtt_start' to prevent ETA clock collision
				vtt_start="${line%% -->*}"
				
				colons="${vtt_start//[^:]/}"
				if [ "${#colons}" -eq 2 ]; then
					IFS=: read -r h m s_ms <<< "$vtt_start"
				else
					h=0
					IFS=: read -r m s_ms <<< "$vtt_start"
				fi
				IFS=. read -r s ms <<< "$s_ms"
				
				total_m=$(( 10#$h * 60 + 10#$m ))
				cs=$(( 10#$ms / 10 ))
				
				current_time=$(printf "[%02d:%02d.%02d]" "$total_m" "$((10#$s))" "$cs")
			
			elif [[ -n "$line" && "$line" != "WEBVTT" ]]; then
				if [[ -n "$current_time" ]]; then
					echo "$current_time $line" >> "$lrc_file"
				fi
			else
				current_time=""
			fi
		done < "$vtt_file"

		rm "$vtt_file"
		echo "  -> Saved: $lrc_file"
	fi

	processed_bytes=$((processed_bytes + file_size))
	last_completed_time=$(date +%s)
done

shopt -u nullglob
echo "Batch transcription complete."
