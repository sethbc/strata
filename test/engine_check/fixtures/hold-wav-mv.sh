#!/bin/sh
# Installed as mv on a private PATH for the files check. Hold the first
# source handed to either carrier. Later sources use the real mv at once.
for arg do part=${dest-}; dest=$arg; done
case $dest in
  */peaks-search-fault/buf1.peaks)
    /bin/mv "$@" || exit $?
    exec chmod 000 "${dest%/*}" ;;
  */held-*.wav) ;;
  *) exec /bin/mv "$@" ;;
esac
if mkdir "$dest.barrier" 2>/dev/null; then
  printf '%s\n' "$part" > "$dest.barrier/source"
fi
if [ "$part" != "$(cat "$dest.barrier/source")" ]; then exec /bin/mv "$@"; fi
early=no
case $dest in */held-ack.wav) /bin/mv "$@" || exit $?; early=yes ;; esac
touch "$dest.barrier/in.$$"
i=0
while [ ! -e "$dest.release" ] && [ "$i" -lt 1000 ]; do
  sleep 0.01
  i=$((i+1))
done
status=0
case $dest in
  */held-failed.wav) status=1 ;;
  *) if [ "$early" = no ]; then /bin/mv "$@" 2>/dev/null || status=$?; fi ;;
esac
touch "$dest.barrier/out.$$"
exit "$status"
