# shellcheck shell=bash
# Shared paths, configuration and platform layer for the session CLI.
#
# SOURCED, NEVER EXECUTED. It sets no shell options, installs no traps, never
# reads stdin, and never sets SESSION_HOME (the entry scripts resolve that from
# their own path before sourcing this file, and the installer consumes it).
# Sourcing it runs no jq, no perl and no process inspection: the hot plumbing
# paths (--focus-mark, --turn-end, …) pay for nothing they do not call.
#
# Everything here is bash 3.2 clean — none of the bash 4/5 constructs the suite's
# case 1 greps for (this file is one of the files it greps, so they are not named
# here) — and free of GNU-only tools outside a named fallback, because macOS ships
# bash 3.2, BSD date, BSD stat, no /proc and no flock(1).

umask 077
# `cd` consults CDPATH for any operand that does not start with / or . — and
# echoes the directory it lands in, so an exported CDPATH both misresolves
# realpath_of's relative operands and adds a line to its captured output.
CDPATH=

SESSION_CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

# The conf is executed verbatim by every hook, every statusline render and every
# CLI call, so a conf other people can write is arbitrary code as this user.
# Checked on the FILE only: a config dir is routinely group-writable (both of
# this machine's are 775), so a directory check would refuse every real conf.
# Skipped rather than fatal — the lib is sourced by the statusline, whose stderr
# Claude Code discards, so exiting there is an unexplained blank status line,
# while skipping keeps every tool running on the defaults and puts the reason in
# front of anyone who runs `session` on a terminal.
_session_conf_trusted() {
  if [ ! -O "$1" ]; then
    echo "session: ignoring $1 — it is not owned by this user (uid $(id -u))" >&2
    return 1
  fi
  if command -v find >/dev/null 2>&1 &&
     [ -n "$(find "$1" \( -perm -0020 -o -perm -0002 \) 2>/dev/null)" ]; then
    echo "session: ignoring $1 — it is group- or world-writable; chmod 600 it" >&2
    return 1
  fi
  return 0
}

# Config file, read BEFORE the SESSION_DATA default so a machine whose data
# lives elsewhere never has a producer resolve the default root first. It exists
# because tmux run-shell, cron, systemd units and Claude Code hooks inherit no
# shell environment: an export in a bashrc reaches none of them.
#
# install.sh writes each line as VAR="${VAR:-value}", so the environment still
# wins per variable, and an environment that sets one variable does not suppress
# the others.
if [ -r "$SESSION_CFG/session.conf" ] && _session_conf_trusted "$SESSION_CFG/session.conf"; then
  . "$SESSION_CFG/session.conf"
fi

SESSION_DATA="${SESSION_DATA_DIR:-$SESSION_CFG/session-usage}"
SESSION_TLOG="$SESSION_DATA/turn-log.tsv"
SESSION_SLOG="$SESSION_DATA/session-log.tsv"
SESSION_FLOG="$SESSION_DATA/focus-log.tsv"
SESSION_PANEDIR="$SESSION_DATA/panes"
SESSION_SNAPDIR="$SESSION_DATA/sessions"
SESSION_ARCHIVE="$SESSION_DATA/archive"
SESSION_RESUME_QUEUE="${SESSION_RESUME_QUEUE:-$SESSION_DATA/resume-queue.tsv}"
SESSION_ACCOUNTS_DIR="${SESSION_ACCOUNTS_DIR:-$SESSION_CFG/accounts}"
# The config dir this machine treats as its primary login. Everything else is a
# secondary account and gets tagged as one — so on a machine whose normal config
# dir is not ~/.claude, session.conf names it here and the tag goes back to
# meaning "not the usual login".
SESSION_PRIMARY_CFG="${SESSION_PRIMARY_CFG:-$HOME/.claude}"
# attended idle-cap: seconds of credit past the last interaction
SESSION_ATTEND_GRACE="${SESSION_ATTEND_GRACE:-600}"
# The tail defaults to the bridge, which is what the single-number model was.
SESSION_ATTEND_TAIL="${SESSION_ATTEND_TAIL:-$SESSION_ATTEND_GRACE}"
# optional script run before `session resume` (a host's own pre-resume guard)
SESSION_TMUX_MAIN_GUARD="${SESSION_TMUX_MAIN_GUARD:-}"
# Whether a cap or authentication death, or the status line seeing the live
# login reach ACCT_SPENT_PCT, may move the box to another vaulted login by
# itself (`session account auto`). `on` or `off`, and nothing else:
# this is the feature's kill switch, so a value it cannot read is refused
# rather than guessed at. Read on every invocation, which is what makes an
# appended `SESSION_AUTO_SWITCH=off` line an instant rollback.
SESSION_AUTO_SWITCH="${SESSION_AUTO_SWITCH:-on}"
# Optional executable called with one argument — the message — when the box
# switches login by itself, and when a blank credential is refused. Empty means
# nothing is sent; the two callers are the only ones, and each covers an event
# the other cannot observe.
SESSION_SWITCH_NOTIFY="${SESSION_SWITCH_NOTIFY:-}"
# Colon-separated task workspaces (each a folder holding tasks/.sync, or a glob
# matching several) whose session-task pointer the statusline reads beside the
# one above the working directory. Empty: only that one is read.
SESSION_TASK_WORKSPACES="${SESSION_TASK_WORKSPACES:-}"
# The live logs keep 8 days (covering the 7-day window); the floor is the day
# below that, inside which a read needs the live file only.
SESSION_LIVE_DAYS=8
# shellcheck disable=SC2034  # read by `session time`'s floor check
SESSION_LIVE_FLOOR_DAYS=$(( SESSION_LIVE_DAYS - 1 ))
# shellcheck disable=SC2034  # read by install.sh
SESSION_BINDIR_DEFAULT="$HOME/.local/bin"
# tests only: a fixed "now" for the date layer
SESSION_NOW="${SESSION_NOW:-}"
# tests only: how many seconds the credential swap waits for each of Claude
# Code's lock directories before it gives up
SESSION_LOCK_WAIT="${SESSION_LOCK_WAIT:-15}"

# ── Login and the per-login cache ────────────────────────────────────────────
# Rate-limit windows are per-login, so the statusline cache, the vault and the
# session log are all keyed by the LOGIN NAME read from the session's own
# config dir: the sanitised email, plus "+<org slug>" when the login is a seat
# in a Team or Enterprise organisation. The suffix exists because one email can
# hold a personal Max plan and a Team seat at once, with separate credentials
# and separate rate-limit windows — keyed by email alone, `/login` into the
# seat overwrote the plan's vault entry and the two logins' windows landed in
# one cache (2026-09-15). A consumer organisation (claude_max, claude_pro,
# claude_free, or none recorded and no seat tier) keeps the bare email, so
# every login vaulted before this rule keeps its name. One jq call in the usual
# case, whatever the shape.
#
# Claude Code sometimes rewrites the profile without organizationType (dropping
# the rate-limit tiers with it), so the type falls back to the seat tier, which
# only a Team or Enterprise seat carries. The fields are split on the unit
# separator, not a tab: tab is IFS whitespace, so an empty type would collapse
# and the next field (the organisation name, or its uuid) would take its slot,
# filing one login under a second name.
#
# The live identity is not the swap's alone to write. Claude Code (observed in
# the 2.1.302 bundle) merges the organisation of whatever token a process holds
# into it whenever the account matches, so after a swap between two
# organisations of one account (one email's personal plan and Team seat), a
# session still holding the outgoing token writes the outgoing organisation
# back, for seconds to hours, while the incoming credential serves every
# request. Named from that identity, the incoming login's windows were cached
# under the outgoing name, the switcher judged the wrong login's headroom from
# them, and acct_save's plan check refused to vault a renewed credential
# (2026-10-17). So when the installed credential's plan contradicts the
# identity's, the live login is the one vaulted entry with the identity's
# email, the credential's plan and the credential's sign-in: the same access
# token, or sign-in ends within a minute of each other, which renewal never
# moves. The sign-in test keeps a swap to another account, caught between its
# two writes, from naming a third login, since the email there is the outgoing
# login's. None or several leave the identity's name, and two organisations of
# one plan type are not distinguished this way.
#
# Between two accounts the identity is rewritten too, by other paths: a session
# saving its in-memory config over the swap's write, or a process that started
# on the outgoing token fetching that account's profile into it (2026-10-19:
# three minutes of one account's windows cached under another's name, and an
# autosave that would have filed its credential there). So every swap records
# the login it installed and that sign-in's end in
# <config dir>/.session-login-installed (acct_swap_locked), and while the
# installed credential is that sign-in (ends within a minute) the record names
# the live login, ahead of both rules here. It is what the swap installed, not
# how the vault is filed: a vault entry that merely holds the credential would,
# if it was ever filed under the wrong name, keep naming the login wrong for the
# life of the sign-in. A credential of another sign-in, as after a /login,
# leaves the record naming nothing. Only the live identity is checked: a file
# passed in is a snapshot or a vault entry, and names itself.
#
# _SESSION_PLAN_CLASH is a jq fragment run on an oauthAccount with $cred bound
# to the credentials file's text. It yields claude_<subscriptionType> when that
# and organizationType are both present and disagree, else "". `try` keeps a
# credentials file that is not valid JSON from failing the read, which would
# name the login unknown; an absent or unreadable one is read as /dev/null.
_SESSION_PLAN_CLASH='(try ($cred | fromjson | .claudeAiOauth.subscriptionType // "") catch "") as $s
  | (.organizationType // "") as $o
  | if $s != "" and $o != "" and $o != "claude_\($s)" then "claude_\($s)" else "" end'
# _SESSION_INSTALLED is a jq fragment with $cred and $inst bound to the
# credentials file's and the swap record's text. It yields the login the record
# names when the installed credential's sign-in end is within a minute of the
# recorded one, else "".
_SESSION_INSTALLED='(try ($cred | fromjson | .claudeAiOauth.refreshTokenExpiresAt // 0) catch 0) as $le
  | ($inst | split("\n")) as $r
  | ($r | map(select(startswith("login=")) | .[6:]) | first // "") as $il
  | ($r | map(select(startswith("end=")) | .[4:] | (tonumber? // 0)) | first // 0) as $ie
  | if $il != "" and ($ie | type) == "number" and $ie > 0 and ($le | type) == "number" and $le > 0
       and (if $ie > $le then $ie - $le else $le - $ie end) <= 60000 then $il else "" end'
session_login_read() {  # [IDENTITY_FILE] — unmemoised: `session account` and the
  local e t n w m v s l cred=/dev/null inst=/dev/null   # mid-wait flip check re-read the live value inside one process
  if [ $# -eq 0 ] && [ -s "$SESSION_CFG/.credentials.json" ] && [ -r "$SESSION_CFG/.credentials.json" ]; then
    cred="$SESSION_CFG/.credentials.json"
    [ -s "$SESSION_CFG/.session-login-installed" ] && [ -r "$SESSION_CFG/.session-login-installed" ] \
      && inst="$SESSION_CFG/.session-login-installed"
  fi
  IFS=$'\037' read -r e t n w m < <(jq -r --rawfile cred "$cred" --rawfile inst "$inst" '.oauthAccount
      | [(.emailAddress // ""),
         (.organizationType // (if (.seatTier // "") != "" then "seat" else "" end)),
         (.organizationName // .organizationUuid // ""),
         ('"$_SESSION_PLAN_CLASH"'),
         ('"$_SESSION_INSTALLED"')]
      | join("\u001f")' "${1:-$SESSION_CFG/.claude.json}" 2>/dev/null || true) || true
  [ -n "$e" ] || { printf 'unknown\n'; return 0; }
  l=$e
  case "$t" in
    ""|claude_max|claude_pro|claude_free) ;;
    *) s=$(printf '%s' "$n" | tr 'A-Z' 'a-z' | sed -e 's/[^a-z0-9]/-/g' -e 's/--*/-/g' -e 's/^-//' -e 's/-$//')
       [ -n "$s" ] || s=$t
       l="$l+$s" ;;
  esac
  l=${l//[!A-Za-z0-9@._+-]/_}
  [ -n "$m" ] && [ "$m" != "$l" ] && { printf '%s\n' "${m//[!A-Za-z0-9@._+-]/_}"; return 0; }
  if [ -n "$w" ] && v=$(_session_vault_entry "$e" "$w" "$cred"); then
    session_login_read "$v"; return 0
  fi
  printf '%s\n' "$l"
}
# The one vault entry with this email and organisation type that holds the
# credential's sign-in (the rule above), or a non-zero return for none, several,
# or a vault jq cannot read through: it stops at an unparseable file, so the
# entries after it would go unexamined and a match before it is not known to
# be the only one.
_session_vault_entry() {  # EMAIL ORGANIZATION_TYPE CREDENTIALS -> a vault path
  local e="$1" t="$2" c="$3" m nl=$'\n'
  set -- "$SESSION_ACCOUNTS_DIR"/*.json
  [ -e "$1" ] || return 1
  m=$(jq -r --arg e "$e" --arg t "$t" --slurpfile c "$c" '
        ($c[0].claudeAiOauth // {}) as $l
        | select(.oauthAccount.emailAddress == $e and .oauthAccount.organizationType == $t)
        | (.claudeAiOauth // {}) as $v
        | ($v.refreshTokenExpiresAt // 0) as $ve | ($l.refreshTokenExpiresAt // 0) as $le
        | select((($v.accessToken // "") != "" and $v.accessToken == $l.accessToken)
                 or ($ve > 0 and $le > 0
                     and (if $ve > $le then $ve - $le else $le - $ve end) <= 60000))
        | input_filename' "$@") || return 1
  case "$m" in ""|*"$nl"*) return 1 ;; esac
  printf '%s\n' "$m"
}
# The file whose oauthAccount is the live login's: .claude.json, or the vault
# entry of the login session_login_read names when that is not the identity's
# (the swap record or a plan clash, both above). For a caller that keeps the identity, not just the name.
session_identity_file() {
  local f="$SESSION_CFG/.claude.json" live
  live=$(session_login_read)
  if [ "$live" != "$(session_login_read "$f")" ] && [ -s "$SESSION_ACCOUNTS_DIR/$live.json" ]; then
    f="$SESSION_ACCOUNTS_DIR/$live.json"
  fi
  printf '%s\n' "$f"
}
# Memoised: read at most once per process, and only when something asks.
_session_login_memo=""
session_login() {
  [ -n "$_session_login_memo" ] || _session_login_memo=$(session_login_read)
  printf '%s\n' "$_session_login_memo"
}

session_cache_path() {  # [LOGIN] [STEM] — defaults to the live login and the statusline's
  # last-status cache; `fable` names the per-login Fable figure `session account`
  # fetches. Sanitised here so every caller keys a login's files identically (trim
  # L2-4: acct_limits used to hand-roll this).
  local l="${1:-$(session_login)}"
  printf '%s\n' "$SESSION_DATA/${2:-last-status}.${l//[!A-Za-z0-9@._+-]/_}.json"
}

# True when this session's config dir is not the machine's primary one — the
# multi-login tag on the statusline and the account line on the overview. The
# comparison is against SESSION_PRIMARY_CFG, not a hardcoded ~/.claude, because
# otherwise every session on a machine that keeps its config elsewhere is tagged
# as a secondary login and the tag stops carrying information. Symlinks are
# resolved on both sides so a linked config dir is not mistaken for another one.
session_nondefault_cfg() {
  # String equality implies path equality — skip the two realpath_of subshell
  # chains (~20 ms/render) on the common case; symlinked spellings still fall
  # through to the resolved comparison.
  [ "$SESSION_CFG" = "$SESSION_PRIMARY_CFG" ] && return 1
  [ "$(realpath_of "$SESSION_CFG")" != "$(realpath_of "$SESSION_PRIMARY_CFG")" ]
}

# ── Time ─────────────────────────────────────────────────────────────────────
now_epoch() { printf '%s\n' "${SESSION_NOW:-$(date +%s)}"; }

# Day boundaries without GNU date. POSIX mktime normalises out-of-range fields
# (mday 0 is the last day of the previous month, mday 32 rolls into the next),
# and isdst=-1 makes it pick the offset in force on that local day — which is
# why a 23-hour or 25-hour DST day comes out right, and why the next day's
# midnight is not midnight+86400.
_session_mktime() {  # $1=kind  $2=YYYY-MM-DD (date kinds only)
  perl -MPOSIX -e '
    my ($base, $kind, $ds) = @ARGV;
    my ($sec,$min,$hour,$mday,$mon,$year) = (localtime($base))[0..5];
    if ($kind eq "date_midnight" || $kind eq "date_next") {
      my ($Y,$M,$D) = $ds =~ /^(\d{4})-(\d{2})-(\d{2})$/;
      defined $D or exit 2;
      # The same normalisation that makes DST days come out right would answer
      # about March 2 for a mistyped "2026-02-30", so the date is round-tripped
      # first. The probe is at NOON because no zone shifts the clock by twelve
      # hours: a real date always reads back as itself, while a local MIDNIGHT
      # that does not exist still resolves instead of being refused.
      my $probe = POSIX::mktime(0,0,12,$D+0,$M-1,$Y-1900,0,0,-1);
      defined $probe or exit 2;
      exit 2 if POSIX::strftime("%Y-%m-%d", localtime($probe)) ne $ds;
      ($sec,$min,$hour,$mday,$mon,$year) = (0,0,0,$D+0,$M-1,$Y-1900);
      $mday++ if $kind eq "date_next";
    } elsif ($kind eq "yesterday_midnight") { ($sec,$min,$hour) = (0,0,0); $mday--; }
    elsif   ($kind eq "yesterday_now")      { $mday--; }
    elsif   ($kind eq "today_midnight")     { ($sec,$min,$hour) = (0,0,0); }
    else    { exit 2 }
    my $e = POSIX::mktime($sec,$min,$hour,$mday,$mon,$year,0,0,-1);
    defined $e or exit 3;
    print "$e\n";
  ' "$(now_epoch)" "$1" "${2:-}"
}

# One refusal for every shape this cannot read, so the message cannot drift
# between the arms that produce it.
_session_date_refuse() {
  echo "session: cannot read the date '$1'. This build accepts 'YYYY-MM-DD 00:00', 'YYYY-MM-DD +1 day', 'yesterday 00:00', 'yesterday' and '00:00'; free-form dates need GNU date." >&2
  exit 2
}

epoch_of() {  # SPEC -> epoch seconds
  local spec="${1:-}"
  case "$spec" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]" 00:00")
        _session_mktime date_midnight "${spec%% *}" || _session_date_refuse "$spec" ;;
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]" +1 day")
        _session_mktime date_next "${spec%% *}" || _session_date_refuse "$spec" ;;
    "yesterday 00:00") _session_mktime yesterday_midnight ;;
    "yesterday")       _session_mktime yesterday_now ;;
    "00:00")           _session_mktime today_midnight ;;
    *)
      # Free text reaches this only through `session time --date`. GNU date
      # parses it; BSD date's -d means something else entirely, so rather than
      # answering with a wrong day this refuses and names what it does accept.
      # The probe asks for a relative date, not just -d: busybox date takes
      # `-d @0` happily and then parses no relative expression at all (probed
      # 2026-08-31 on alpine), so probing -d alone would hand free text to a
      # date(1) that cannot read it.
      if date -d 'yesterday 00:00' +%s >/dev/null 2>&1; then
        date -d "$spec" +%s
      else
        _session_date_refuse "$spec"
      fi
      ;;
  esac
}

fmt_epoch() {  # N FMT -> the formatted local time
  perl -MPOSIX -e 'print POSIX::strftime($ARGV[1], localtime($ARGV[0])), "\n"' "$1" "$2"
}

# Sub-second stamp for focus rows. `date +%s.%3N` is GNU-only: BSD date prints
# the %3N literally, and every "$1+0" comparison downstream then reads 0.
epoch_ms() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }

# ── Process inspection ───────────────────────────────────────────────────────
# /proc on Linux, ps elsewhere. Tests override this predicate to exercise the
# ps branch on a machine that has /proc.
session_have_proc() { [ -d /proc/self ]; }

proc_ppid() {  # PID -> parent pid
  local pid="${1:-}" p=""
  if session_have_proc; then
    [ -r "/proc/$pid/status" ] || return 1
    p=$(sed -n 's/^PPid:[[:space:]]*//p' "/proc/$pid/status")
  else
    p=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  fi
  [ -n "$p" ] || return 1
  printf '%s\n' "$p"
}

proc_cmdline() {  # PID -> one argv word per line
  local pid="${1:-}"
  if session_have_proc; then
    [ -r "/proc/$pid/cmdline" ] || return 1
    tr '\0' '\n' < "/proc/$pid/cmdline"
  else
    # ps gives one flat string; splitting on spaces is what lets a caller match
    # a whole word (`grep -qx -- -p`) rather than a substring of another argument.
    ps -o command= -p "$pid" 2>/dev/null | tr ' ' '\n'
  fi
}

proc_env() {  # PID VAR -> the variable's value in that process's environment
  local pid="${1:-}" var="${2:-}"
  if session_have_proc; then
    [ -r "/proc/$pid/environ" ] || return 1
    tr '\0' '\n' < "/proc/$pid/environ"
  else
    # macOS prints the environment of the user's own processes here; Linux procps
    # rejects -E, so this branch is Darwin-only and unverified on a real Mac.
    ps -Eww -o command= -p "$pid" 2>/dev/null | tr ' ' '\n'
  fi | awk -v v="$var" 'index($0, v "=") == 1 { print substr($0, length(v) + 2); exit }'
}

# ── Files ────────────────────────────────────────────────────────────────────
# `readlink -f` is GNU-only and `realpath` is not everywhere either, so the walk
# is done here: follow symlinks by hand, then resolve the containing directory
# physically. A path whose directory does not exist comes back unchanged.
realpath_of() {
  # Cleared here too, not only at the top of the file: this one is called by
  # other people's code, and a caller that sets CDPATH for the call would
  # otherwise get a path resolved inside some other tree, with the directory cd
  # echoed into the answer as a second line.
  local CDPATH='' p="${1:-}" d b n=0
  while [ -L "$p" ] && [ "$n" -lt 40 ]; do
    d=$(cd -P "$(dirname -- "$p")" 2>/dev/null && pwd -P) || break
    p=$(ls -ld "$p" | sed 's/.*-> //')
    case "$p" in /*) ;; *) p="$d/$p" ;; esac
    n=$(( n + 1 ))
  done
  d=$(cd -P "$(dirname -- "$p")" 2>/dev/null && pwd -P) || { printf '%s\n' "$p"; return 0; }
  b=$(basename "$p")
  case "$b" in
    /) printf '/\n' ;;
    *) case "$d" in
         /) printf '/%s\n' "$b" ;;
         *) printf '%s/%s\n' "$d" "$b" ;;
       esac ;;
  esac
}

mtime_of() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }

# ── Locking ──────────────────────────────────────────────────────────────────
# The prune treats any non-zero as "somebody else holds it, or the command did
# not run — skip either way", and needs no finer distinction. The backends do
# not agree on a code for BUSY and are not made to: util-linux flock has -E,
# busybox flock does not, and the perl path picks its own, so a caller that
# has to tell busy from broken reads 1 and 75 as one set.
#
# A lock file that cannot be OPENED must not wear either of those codes: the
# decision verb's callers read busy as "another decision is in flight" and fall
# through with no retry, no row and no message, so a switch.lock left unopenable
# would disable automatic switching for ever and say nothing about it.
#
# The two backends do not open the same file the same way, so this is not one
# condition with one code, and a caller must not be written as though it were.
# flock(1) opens O_RDONLY|O_CREAT and answers out of <sysexits.h>: 66 when it
# cannot open an existing file, 73 when it cannot create a missing one
# (read-only filesystem, no space), 71 on resource exhaustion. The perl path
# opens for append, which is a stricter test — a read-only or foreign-owned
# lock file it cannot write is 66 while flock(1) takes the lock and runs. So
# the perl path, the one macOS takes, is where an unopenable switch.lock
# actually bites, and 66 is the code it reports for every flavour of it.
# What every caller needs is the same on both: none of 66, 73 or 71 is busy.
lock_run() {  # LOCK CMD... -> the command's status, or non-zero if it never ran
  local lock="$1"
  shift
  if command -v flock >/dev/null 2>&1; then
    flock -n "$lock" "$@"
  else
    # $^F=10 is load-bearing. Perl sets FD_CLOEXEC on every descriptor above $^F
    # (default 2), so without it the lock is released by the exec and there is no
    # mutual exclusion at all — the failure looks like success. LOCK_EX|LOCK_NB
    # is 6; the block form of exec bypasses /bin/sh even for a one-word command.
    # The trailing exit is not decoration: perl's exec RETURNS on failure, and
    # without it the one-liner falls off the end reporting 0 — a caller would
    # read "the command ran" for a command that never started. 127 is the shell's
    # code for that, and flock(1) likewise reports non-zero.
    perl -e '$^F=10; open(F,">>",$ARGV[0]) or exit 66; flock(F,6) or exit 75; exec {$ARGV[1]} @ARGV[1..$#ARGV]; exit 127' "$lock" "$@"
  fi
}

# ── Host ─────────────────────────────────────────────────────────────────────
reboot_cmd() {
  if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl reboot
  else
    sudo shutdown -r now
  fi
}

# ── Daily prune ──────────────────────────────────────────────────────────────
# The live logs keep SESSION_LIVE_DAYS days so every reader stays fast; older
# rows move to archive/<same name>, append-only and never expired — the history
# is deliberately permanent. Callable from both producers (the statusline render
# and --session-end) behind one marker, so neither has to be installed for the
# logs to stay bounded.
session_prune_daily() {
  [ -d "$SESSION_DATA" ] || return 0
  local marker="$SESSION_DATA/.session-log-pruned" now cut lg tmp
  now=$(now_epoch)
  if [ -e "$marker" ]; then
    [ $(( now - $(mtime_of "$marker") )) -ge 86400 ] || return 0
  fi
  # Marker first: a prune that dies half way just retries tomorrow.
  touch "$marker"
  [ -d "$SESSION_ARCHIVE" ] || mkdir -p "$SESSION_ARCHIVE"
  cut=$(( now - SESSION_LIVE_DAYS * 86400 ))
  # awk reads the archive path from the environment rather than through -v,
  # which processes escape sequences in the value: a data root containing a
  # backslash would send the archive writes somewhere else entirely.
  export SESSION_PRUNE_ARCHIVE
  for lg in "$SESSION_SLOG" "$SESSION_TLOG" "$SESSION_FLOG"; do
    [ -s "$lg" ] || continue
    # The temp name carries the pid because THIS shell creates and truncates it
    # before lock_run ever tests the lock. Under a shared name the producer that
    # loses the lock truncates the winner's file mid-write and then deletes it,
    # so the winner's mv fails, the rows stay in the live log AND in the archive,
    # and the marker still records the day as pruned. There are two producers
    # (every statusline render, every --session-end), so that race is drawn often.
    tmp="$lg.tmp.$$"
    SESSION_PRUNE_ARCHIVE="$SESSION_ARCHIVE/${lg##*/}"
    if lock_run "$lg.lock" awk -F'\t' -v cut="$cut" \
         '$1+0 >= cut { print; next } { print >> ENVIRON["SESSION_PRUNE_ARCHIVE"] }' "$lg" > "$tmp"; then
      mv -f "$tmp" "$lg"
    else
      # A busy code (1 from flock(1), 75 from perl) is another producer holding
      # the lock, which is normal and silent; 66 is a lock file that cannot be
      # opened and anything else a command that did not run to completion. All
      # of them mean the temp is not a replacement for the live log — the one
      # thing this must never get wrong, since the live log is the only copy of
      # the recent rows.
      rm -f "$tmp"
    fi
  done
  unset SESSION_PRUNE_ARCHIVE
  [ -d "$SESSION_SNAPDIR" ] && find "$SESSION_SNAPDIR" -type f -mtime +8 -delete
  [ -d "$SESSION_PANEDIR" ] && find "$SESSION_PANEDIR" -type f -mtime +8 -delete
  return 0
}
