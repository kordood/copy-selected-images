#!/bin/bash

usage() {
    echo "Usage: $0 TARGET_DIR [DEST_DIR] [RAW_DIR]"
    exit 1
}

# 이미 스크립트로 복사된 파일인지 확인하는 함수
is_already_copied() {
    local file="$1"
    local dest_dir="$2"
    local target_dir="$3"
    # 대상 디렉터리와 원본 디렉터리가 다르면 체크하지 않음
    if [ "$dest_dir" != "$target_dir" ]; then
        return 1  # false
    fi
    # TARGET_DIR 기준 상대 경로 구하기
    local rel="${file#$target_dir/}"
    if [[ "$rel" == */* ]]; then
        local first_dir="${rel%%/*}"
        # 해당 하위 디렉터리에 marker 파일이 있으면, 스크립트로 생성된 태그 폴더임
        if [ -f "$dest_dir/$first_dir/.copy_by_tags" ]; then
            return 0  # true: 이미 복사된 파일
        fi
    fi
    return 1  # false
}

# 동일 파일명이 존재할 경우, 파일 내용이 동일하면 복사를 건너뛰고,
# 내용이 다르면 기존 복사본 중 가장 큰 suffix 숫자 다음 숫자를 붙여 복사하는 함수
copy_with_suffix() {
    local src="$1"
    local dest_dir="$2"
    local base
    base=$(basename "$src")
    local ext="${base##*.}"
    local name="${base%.*}"
    local dest_file="$dest_dir/$base"

    # 대상 파일이 없으면 그대로 복사
    if [ ! -f "$dest_file" ]; then
        cp "$src" "$dest_file"
        return
    else
        # 대상 파일이 존재하면 파일 내용 비교: 동일하면 복사하지 않음
        if cmp -s "$src" "$dest_file"; then
            return
        fi
    fi

    shopt -s nullglob
    local max=0
    for candidate in "$dest_dir"/"$name"-*."$ext"; do
        if [ -f "$candidate" ]; then
            # 내용이 동일하면 복사하지 않음
            if cmp -s "$src" "$candidate"; then
                shopt -u nullglob
                return
            fi
            local fname
            fname=$(basename "$candidate")
            # candidate 파일명이 "name-숫자.ext" 형태인 경우, 숫자 부분 추출
            local num="${fname#$name-}"
            num="${num%.$ext}"
            if [[ "$num" =~ ^[0-9]+$ ]]; then
                if [ "$num" -ge "$max" ]; then
                    max=$((num + 1))
                fi
            fi
        fi
    done
    shopt -u nullglob

    dest_file="$dest_dir/${name}-${max}.${ext}"
    cp "$src" "$dest_file"
}

# RAW 파일 복사 함수: 원본 파일명과 동일한 이름의 RAW 확장자 파일을 찾아 복사
copy_raw_files() {
    local file="$1"
    local tag="$2"
    local target_dir="$3"
    local raw_dir="$4"
    local raw_exts=(".raw" ".dng" ".arw" ".cr2" ".cr3" ".crw" ".nef" ".orf" ".raf" ".rw2" ".rwl" ".x3f")
    local base
    base=$(basename "$file")
    local name="${base%.*}"

    for ext in "${raw_exts[@]}"; do
        # 대소문자 구분 없이 RAW 파일 탐색 (첫 번째 매칭 결과만 사용)
        RAW_FILE=$(find "$target_dir" -type f -iname "${name}${ext}" | head -n 1)
        if [ -n "$RAW_FILE" ]; then
            mkdir -p "$raw_dir/$tag"
            # marker 파일 생성: 이 디렉터리가 스크립트로 생성된 태그 폴더임을 표시
            if [ ! -f "$raw_dir/$tag/.copy_by_tags" ]; then
                touch "$raw_dir/$tag/.copy_by_tags"
            fi
            copy_with_suffix "$RAW_FILE" "$raw_dir/$tag"
        fi
    done
}

# 한 파일을 처리: 태그 정보를 읽어 태그별 디렉터리에 파일과 관련 RAW 파일을 복사
process_file() {
    local file="$1"
    local target_dir="$2"
    local dest_dir="$3"
    local raw_dir="$4"

    # DEST_DIR와 TARGET_DIR가 동일할 경우, 이미 복사된 파일은 건너뜀
    if is_already_copied "$file" "$dest_dir" "$target_dir"; then
        return
    fi

    local tags
    tags=$(mdls -raw -name kMDItemUserTags "$file")
    if [[ "$tags" == "(null)" ]]; then
        return
    fi
    # 태그 문자열에서 괄호, 따옴표, 쉼표 제거 (예: ( "Red", "Blue" ) -> Red Blue)
    tags=$(echo "$tags" | sed 's/[()",]//g')
    for tag in $tags; do
        if [ -n "$tag" ]; then
            mkdir -p "$dest_dir/$tag"
            # marker 파일 생성: 이 디렉터리가 스크립트로 생성된 태그 폴더임을 표시
            if [ ! -f "$dest_dir/$tag/.copy_by_tags" ]; then
                touch "$dest_dir/$tag/.copy_by_tags"
            fi
            copy_with_suffix "$file" "$dest_dir/$tag"
            copy_raw_files "$file" "$tag" "$target_dir" "$raw_dir"
        fi
    done
}

# --- Main ---

TARGET_DIR="$1"
DEST_DIR="${2:-$TARGET_DIR}"
RAW_DIR="${3:-$DEST_DIR}"

if [ -z "$TARGET_DIR" ]; then
    usage
fi

#####################################
# Phase 1: Filtering files with tags
#####################################
echo "Phase 1: Filtering files with tags..."

# 전체 파일 개수를 먼저 파악 (필터링 진행 상황 표시용)
total_all=$(find "$TARGET_DIR" -type f | wc -l)
count_all=0
files_with_tags=()

# find 결과를 순회하며 태그 정보가 있는 파일만 배열에 저장
while IFS= read -r file; do
    count_all=$((count_all + 1))
    echo -ne "Filtering progress: $count_all / $total_all files processed\r"
    if [ "$(mdls -raw -name kMDItemUserTags "$file")" != "(null)" ]; then
        files_with_tags+=("$file")
    fi
done < <(find "$TARGET_DIR" -type f)
echo ""
echo "Phase 1 complete: Found ${#files_with_tags[@]} files with tags."

###############################################
# Phase 2: Processing file copy (filtered files)
###############################################
echo "Phase 2: Processing file copy..."
total=${#files_with_tags[@]}
count=0
for file in "${files_with_tags[@]}"; do
    count=$((count + 1))
    process_file "$file" "$TARGET_DIR" "$DEST_DIR" "$RAW_DIR"
    echo -ne "Processing progress: $count / $total files processed\r"
done
echo ""
echo "Phase 2 complete: Processed $count files."