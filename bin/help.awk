# help.awk — render a script's top comment block as help text.
#
# Reads a script file and prints its header block (the run of `#` comment lines
# right after the shebang). Controlled by -v pretty=0|1; the caller (not this
# script) decides whether stdout is a tty.
#
#   pretty=0  IDENTITY — byte-for-byte the same as the historical one-liner
#             awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}'
#             (skip the shebang, strip the leading "# ", stop at the first
#             non-`#` line). This is the non-tty / regression path.
#
#   pretty=1  STYLED — buffer the block, then emit with bold/dim only:
#             - first line of the block (the title) → bold
#             - a line ending in `:` (section heading)  → bold
#             - a line containing ` # ` (a command row) → split at the first
#               ` # `: the command is padded to the block's widest command and
#               the description (the literal `#` dropped) is printed dim
#             - blank lines → printed as-is
#             - any other prose line → dim
#
# Generic on purpose: the same program renders the dispatcher header and any
# subcommand header (e.g. a `Usage:` block with ` # ` rows).

function bold(s) { return "\033[1m" s "\033[0m" }
function dim(s)  { return "\033[2m" s "\033[0m" }

BEGIN { n = 0; maxw = 0; done = 0 }

NR == 1 { next }        # shebang
done    { next }        # past the header block (pretty=1 buffers, never exits)

/^#/ {
  line = $0
  sub(/^# ?/, "", line)

  if (pretty == 0) { print line; next }   # identity path — emit immediately

  buf[n] = line
  if (index(line, " # ") > 0) {
    p = index(line, " # ")
    l = substr(line, 1, p - 1)            # command (before the " # ")
    r = substr(line, p + 3)               # description (after "space#space")
    sub(/[ \t]+$/, "", l)                 # trim trailing pad on the command
    sub(/^[ \t]+/, "", r)                 # trim leading space on the description
    iscmd[n] = 1; cleft[n] = l; cright[n] = r
    if (length(l) > maxw) maxw = length(l)
  }
  n++
  next
}

{
  if (pretty == 0) exit                   # first non-`#` line ends the block
  done = 1                                # pretty=1: stop buffering, emit in END
  next
}

END {
  if (pretty != 1) exit
  for (i = 0; i < n; i++) {
    if (i == 0)          { print bold(buf[i]); continue }   # title
    if (buf[i] == "")    { print "";           continue }   # blank
    if (iscmd[i]) {
      pad = maxw - length(cleft[i]); sp = ""
      while (pad-- > 0) sp = sp " "
      print cleft[i] sp "  " dim(cright[i])
      continue
    }
    if (buf[i] ~ /:[ \t]*$/) { print bold(buf[i]); continue }   # section heading
    print dim(buf[i])                                            # prose
  }
}
