# Validate AndroidJUnitRunner's raw (-r) output, including the final result
# bundle. adb itself may return success for test failures and process crashes.
{ sub(/\r$/, "") }
/^INSTRUMENTATION_STATUS: class=/ { class = substr($0, index($0, "=") + 1) }
/^INSTRUMENTATION_STATUS: test=/ { method = substr($0, index($0, "=") + 1) }
/^INSTRUMENTATION_STATUS: numtests=/ { planned = substr($0, index($0, "=") + 1) + 0 }
/^INSTRUMENTATION_STATUS_CODE:/ {
    if ($2 == 0 || $2 == -3 || $2 == -4) completed++
    if ($2 == 0) passed[class "#" method] = 1
    if ($2 < 0 && $2 != -3 && $2 != -4) failed = 1
    class = method = ""
}
/^OK \([1-9][0-9]* tests?\)$/ { summary = 1 }
/^INSTRUMENTATION_CODE: -1$/ { finished = 1 }
END {
    count = split(required, cases, " ")
    for (i = 1; i <= count; i++) {
        if (!(cases[i] in passed)) {
            print "Required Android test did not pass: " cases[i] > "/dev/stderr"
            failed = 1
        }
    }
    if (!finished || !summary || !planned || completed != planned || !length(passed) || failed) {
        print "Incomplete or unsuccessful Android instrumentation run (" completed "/" planned ")." > "/dev/stderr"
        exit 1
    }
}
