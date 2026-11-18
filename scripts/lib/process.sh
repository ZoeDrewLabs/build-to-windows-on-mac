# process.sh — rodar com tempo limite, esperar a garrafa e limpar processos que sobram.

# run_timeout SEGUNDOS comando... → código de saída do comando, ou 124 se estourou o tempo
# (aí encerra o comando e o wineserver da garrafa atual, para não deixar processos órfãos).
run_timeout() {
  local secs="$1" pid t=0 rc; shift
  "$@" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if (( t >= secs )); then
      echo "tempo esgotado (${secs}s): ${1:t} — encerrando" | tee -a "$LOG"
      kill "$pid" 2>/dev/null
      "$WINESERVER" -k 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 1; (( t++ ))
  done
  wait "$pid"; rc=$?
  return $rc
}

# Espera todos os processos da garrafa atual terminarem (no máximo $1 segundos).
wait_prefix() { run_timeout "${1:-120}" "$WINESERVER" -w; }

# Encerra tudo de uma garrafa (ou de todas, sem argumento).
kill_prefix() {
  local p
  if [[ -n "${1:-}" ]]; then
    WINEPREFIX="$PREFIXES/$1" "$WINESERVER" -k 2>/dev/null
  else
    for p in "$PREFIXES"/*(N/); do WINEPREFIX="$p" "$WINESERVER" -k 2>/dev/null; done
  fi
}

# Roda o wine na garrafa atual (WINEPREFIX já exportado por use_prefix) com saída no log.
# wine_run SEGUNDOS args...   (0 = sem esperar: roda solto, para programas que a pessoa usa)
# Atenção: nunca chamar via /usr/bin/env — ele é protegido pelo macOS e apaga as variáveis
# DYLD_*, e o Wine deixa de achar as bibliotecas.
wine_run() {
  local secs="$1"; shift
  [[ -n "${WINEPREFIX:-}" ]] || { echo "wine_run sem garrafa"; return 1; }
  if [[ "$secs" == 0 ]]; then
    "$WINE" "$@" >>"$LOG" 2>&1 &!
    return 0
  fi
  run_timeout "$secs" "$WINE" "$@" >>"$LOG" 2>&1
}
