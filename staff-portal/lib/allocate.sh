# Shell mirror of app/allocate.py. alloc_group <group> <n> -> space-sep indices.
alloc_group() {
  # half_hi = ceil(N/2) for Dev/QA split; half_lo = floor(N/2) for Marketing top.
  local g="$1" n="$2" half_lo=$(( $2 / 2 )) half_hi=$(( ($2 + 1) / 2 )) quarter=$(( $2 / 4 )) i out=""
  case "$g" in
    All_Company)    for ((i=1;i<=n;i++)); do out+="$i "; done ;;
    Dev_Team)       for ((i=1;i<=half_hi;i++)); do out+="$i "; done ;;
    QA_Team)        for ((i=half_hi+1;i<=n;i++)); do out+="$i "; done ;;
    Support_Team)   for ((i=1;i<=quarter;i++)); do out+="$i "; done ;;
    Marketing_Team) for ((i=quarter+1;i<=half_lo;i++)); do out+="$i "; done ;;
  esac
  echo "${out% }"
}
