#!/bin/sh
# A made-up agent for the README screenshot: names its tile, prints believable work, and ends up
# asking, working, failed or done. Usage: agent.sh <title> ask|work|fail|done|logs
title=$1
printf '\033]0;%s\007' "$title"
dim='\033[2m' green='\033[32m' red='\033[31m' cyan='\033[36m' bold='\033[1m' off='\033[0m'
step() { printf "${cyan}●${off} %s\n" "$1"; sleep 0.25; }
case $2 in
ask)
  step "Read src/auth/session.ts (212 lines)"
  step "Read src/auth/refresh.ts (98 lines)"
  printf "\nThe session TTL is set in two places and they disagree (15 min vs 30 min).\n"
  printf "I'll move it to config/auth.ts and read it from both.\n\n"
  printf "${dim}  src/auth/session.ts\n  - const TTL = 15 * 60\n  + import { SESSION_TTL } from '../../config/auth'${off}\n\n"
  printf "${bold}Do you want to make this edit to src/auth/session.ts? (y/n)${off} "
  read -r _ ;;
work)
  i=1
  while :; do
    printf "${dim}[build]${off} compiling module %d of 480 ... ${green}ok${off}\n" "$i"
    i=$((i % 480 + 1)); sleep 0.2
  done ;;
fail)
  step "Run npm test"
  printf "\n PASS  tests/cart.test.ts\n PASS  tests/pricing.test.ts\n ${red}FAIL${off}  tests/tax.test.ts\n"
  printf "   ✕ applies VAT to digital goods (14 ms)\n     Expected: 120.00\n     Received: 100.00\n\n"
  printf "Tests: ${red}1 failed${off}, 41 passed, 42 total\n"
  sleep 1; exit 1 ;;
done)
  for f in parser lexer resolver emitter optimizer linker; do
    printf "${dim}[test]${off} %-10s ${green}✓${off} %d passed\n" "$f" $((RANDOM % 30 + 5)); sleep 0.45
  done
  printf "\n${green}${bold}All 132 tests passed${off} in 3.1s\n"
  while :; do sleep 3600; done ;;
logs)
  while :; do
    printf "${dim}%s${off} GET /api/v2/orders ${green}200${off} %dms\n" "$(date +%H:%M:%S)" $((RANDOM % 80 + 12))
    sleep 1.5
  done ;;
esac
