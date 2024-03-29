#!/bin/bash
#
# run OpenVPN client against ``test reference'' server
# - check that ping, http, ... via tunnel works
# - check that interface config / routes are properly cleaned after test end
#
# prerequisites:
# - openvpn binary in current directory
# - writable current directory to create subdir for logs
# - t_client.rc in current directory OR source dir that specifies tests
# - for "ping4" checks: fping binary in $PATH
# - for "ping6" checks: fping6 binary in $PATH
#

srcdir="${srcdir:-.}"
top_builddir="${top_builddir:-..}"
if [ -r "${top_builddir}"/t_client.rc ] ; then
    . "${top_builddir}"/t_client.rc
elif [ -r "${srcdir}"/t_client.rc ] ; then
    . "${srcdir}"/t_client.rc
else
    echo "$0: cannot find 't_client.rc' in build dir ('${top_builddir}')" >&2
    echo "$0: or source directory ('${srcdir}'). SKIPPING TEST." >&2
    exit 77
fi

# Check for external dependencies
which fping > /dev/null
if [ $? -ne 0 ]; then
    echo "$0: fping is not available in \$PATH" >&2
    exit 77
fi
which fping6 > /dev/null
if [ $? -ne 0 ]; then
    echo "$0: fping6 is not available in \$PATH" >&2
    exit 77
fi

KILL_EXEC=`which kill`
if [ $? -ne 0 ]; then
    echo "$0: kill not found in \$PATH" >&2
    exit 77
fi

if [ ! -x "${top_builddir}/src/openvpn/openvpn" ]
then
    echo "no (executable) openvpn binary in current build tree. FAIL." >&2
    exit 1
fi

if [ ! -w . ]
then
    echo "current directory is not writable (required for logging). FAIL." >&2
    exit 1
fi

if [ -z "$CA_CERT" ] ; then
    echo "CA_CERT not defined in 't_client.rc'. SKIP test." >&2
    exit 77
fi

if [ -z "$TEST_RUN_LIST" ] ; then
    echo "TEST_RUN_LIST empty, no tests defined.  SKIP test." >&2
    exit 77
fi

# Ensure PREFER_KSU is in a known state
PREFER_KSU="${PREFER_KSU:-0}"

# make sure we have permissions to run ifconfig/route from OpenVPN
# can't use "id -u" here - doesn't work on Solaris
ID=`id`
if expr "$ID" : "uid=0" >/dev/null
then :
else
    if [ "${PREFER_KSU}" -eq 1 ];
    then
        # Check if we have a valid kerberos ticket
        klist -l 1>/dev/null 2>/dev/null
        if [ $? -ne 0 ];
        then
            # No kerberos ticket found, skip ksu and fallback to RUN_SUDO
            PREFER_KSU=0
            echo "$0: No Kerberos ticket available.  Will not use ksu."
        else
            RUN_SUDO="ksu -q -e"
        fi
    fi

    if [ -z "$RUN_SUDO" ]
    then
        echo "$0: this test must run be as root, or RUN_SUDO=... " >&2
        echo "      must be set correctly in 't_client.rc'. SKIP." >&2
        exit 77
    else
        # We have to use sudo. Make sure that we (hopefully) do not have
        # to ask the users password during the test. This is done to
        # prevent timing issues, e.g. when the waits for openvpn to start
	if $RUN_SUDO $KILL_EXEC -0 $$
	then
	    echo "$0: $RUN_SUDO $KILL_EXEC -0 succeeded, good."
	else
	    echo "$0: $RUN_SUDO $KILL_EXEC -0 failed, cannot go on. SKIP." >&2
	    exit 77
	fi
    fi
fi

LOGDIR=t_client-`hostname`-`date +%Y%m%d-%H%M%S`
if mkdir $LOGDIR
then :
else
    echo "can't create log directory '$LOGDIR'. FAIL." >&2
    exit 1
fi

exit_code=0

# ----------------------------------------------------------
# helper functions
# ----------------------------------------------------------

# print failure message, increase FAIL counter
fail()
{
    echo ""
    echo "FAIL: $@" >&2
    fail_count=$(( $fail_count + 1 ))
}

# print "all interface IP addresses" + "all routes"
# this is higly system dependent...
get_ifconfig_route()
{
    # linux / iproute2? (-> if configure got a path)
    if [ -n "/sbin/ip" ]
    then
	echo "-- linux iproute2 --"
	/sbin/ip addr show     | grep -v valid_lft
	/sbin/ip route show
	/sbin/ip -o -6 route show | grep -v ' cache' | sed -E -e 's/ expires [0-9]*sec//' -e 's/ (mtu|hoplimit|cwnd|ssthresh) [0-9]+//g' -e 's/ (rtt|rttvar) [0-9]+ms//g'
	return
    fi

    # try uname
    case `uname -s` in
	Linux)
	   echo "-- linux / ifconfig --"
	   LANG=C /sbin/ifconfig -a |egrep  "( addr:|encap:)"
	   LANG=C netstat -rn -4 -6
	   return
	   ;;
	FreeBSD|NetBSD|Darwin)
	   echo "-- FreeBSD/NetBSD/Darwin [MacOS X] --"
	   /sbin/ifconfig -a | egrep "(flags=|inet)"
	   netstat -rn | awk '$3 !~ /^UHL/ { print $1,$2,$3,$NF }'
	   return
	   ;;
	OpenBSD)
	   echo "-- OpenBSD --"
	   /sbin/ifconfig -a | egrep "(flags=|inet)" | \
		sed -e 's/pltime [0-9]*//' -e 's/vltime [0-9]*//'
	   netstat -rn | awk '$3 !~ /^UHL/ { print $1,$2,$3,$NF }'
	   return
	   ;;
	SunOS)
	   echo "-- Solaris --"
	   /sbin/ifconfig -a | egrep "(flags=|inet)"
	   netstat -rn | awk '$3 !~ /^UHL/ { print $1,$2,$3,$6 }'
	   return
	   ;;
	AIX)
	   echo "-- AIX --"
	   /sbin/ifconfig -a | egrep "(flags=|inet)"
	   netstat -rn | awk '$3 !~ /^UHL/ { print $1,$2,$3,$6 }'
	   return
	   ;;
    esac

    echo "get_ifconfig_route(): no idea how to get info on your OS.  FAIL." >&2
    exit 20
}

# ----------------------------------------------------------
# check ifconfig
#  arg1: "4" or "6" -> for message
#  arg2: IPv4/IPv6 address that must show up in out of "get_ifconfig_route"
check_ifconfig()
{
    proto=$1 ; shift
    expect_list="$@"

    if [ -z "$expect_list" ] ; then return ; fi

    for expect in $expect_list
    do
	if get_ifconfig_route | fgrep "$expect" >/dev/null
	then :
	else
	    fail "check_ifconfig(): expected IPv$proto address '$expect' not found in ifconfig output."
	fi
    done
}

# ----------------------------------------------------------
# run pings
#  arg1: "4" or "6" -> fping/fing6
#  arg2: "want_ok" or "want_fail" (expected ping result)
#  arg3... -> fping arguments (host list)
run_ping_tests()
{
    proto=$1 ; want=$2 ; shift ; shift
    targetlist="$@"

    # "no targets" is fine
    if [ -z "$targetlist" ] ; then return ; fi

    case $proto in
	4) cmd=fping ;;
	6) cmd=fping6 ;;
	*) echo "internal error in run_ping_tests arg 1: '$proto'" >&2
	   exit 1 ;;
    esac

    case $want in
	want_ok)   sizes_list="64 1440 3000" ;;
	want_fail) sizes_list="64" ;;
    esac

    for bytes in $sizes_list
    do
	echo "run IPv$proto ping tests ($want), $bytes byte packets..."

	echo "$cmd -b $bytes -C 20 -p 250 -q $FPING_EXTRA_ARGS $targetlist" >>$LOGDIR/$SUF:fping.out
	$cmd -b $bytes -C 20 -p 250 -q $FPING_EXTRA_ARGS $targetlist >>$LOGDIR/$SUF:fping.out 2>&1

	# while OpenVPN is running, pings must succeed (want='want_ok')
	# before OpenVPN is up, pings must NOT succeed (want='want_fail')

	rc=$?
	if [ $rc = 0 ] 				# all ping OK
	then
	    if [ $want = "want_fail" ]		# not what we want
	    then
		fail "IPv$proto ping test succeeded, but needs to *fail*."
	    fi
	else					# ping failed
	    if [ $want = "want_ok" ]		# not what we wanted
	    then
		fail "IPv$proto ping test ($bytes bytes) failed, but should succeed."
	    fi
	fi
    done
}

# ----------------------------------------------------------
# main test loop
# ----------------------------------------------------------
SUMMARY_OK=
SUMMARY_FAIL=

for SUF in $TEST_RUN_LIST
do
    # get config variables
    eval test_prep=\"\$PREPARE_$SUF\"
    eval test_postinit=\"\$POSTINIT_CMD_$SUF\"
    eval test_cleanup=\"\$CLEANUP_$SUF\"
    eval test_run_title=\"\$RUN_TITLE_$SUF\"
    eval openvpn_conf=\"\$OPENVPN_CONF_$SUF\"
    eval expect_ifconfig4=\"\$EXPECT_IFCONFIG4_$SUF\"
    eval expect_ifconfig6=\"\$EXPECT_IFCONFIG6_$SUF\"
    eval ping4_hosts=\"\$PING4_HOSTS_$SUF\"
    eval ping6_hosts=\"\$PING6_HOSTS_$SUF\"

    # If EXCEPT_IFCONFIG* variables for this test are missing, run an --up
    # script to generate them dynamically.
    if [ -z "$expect_ifconfig4" ] || [ -z "$expect_ifconfig6" ]; then
        up="--setenv TESTNUM $SUF --setenv TOP_BUILDDIR ${top_builddir} --script-security 2 --up ${srcdir}/update_t_client_ips.sh"
    else
        up=""
    fi

    echo -e "\n### test run $SUF: '$test_run_title' ###\n"
    fail_count=0

    if [ -n "$test_prep" ]; then
        echo -e "running preparation: '$test_prep'"
        eval $test_prep
    fi

    echo "save pre-openvpn ifconfig + route"
    get_ifconfig_route >$LOGDIR/$SUF:ifconfig_route_pre.txt

    echo -e "\nrun pre-openvpn ping tests - targets must not be reachable..."
    run_ping_tests 4 want_fail "$ping4_hosts"
    run_ping_tests 6 want_fail "$ping6_hosts"
    if [ "$fail_count" = 0 ] ; then
        echo -e "OK.\n"
    else
	echo -e "FAIL: make sure that ping hosts are ONLY reachable via VPN, SKIP test $SUF".
	exit_code=31
	continue
    fi

    pidfile="${top_builddir}/tests/$LOGDIR/openvpn-$SUF.pid"
    openvpn_conf="$openvpn_conf --writepid $pidfile $up"
    echo " run openvpn $openvpn_conf"
    echo "# src/openvpn/openvpn $openvpn_conf" >$LOGDIR/$SUF:openvpn.log
    umask 022
    $RUN_SUDO "${top_builddir}/src/openvpn/openvpn" $openvpn_conf >>$LOGDIR/$SUF:openvpn.log &
    sudopid=$!

    # Check if OpenVPN has initialized before continuing.  It will check every 3rd second up
    # to $ovpn_init_check times.
    ovpn_init_check=10
    ovpn_init_success=0
    while [ $ovpn_init_check -gt 0 ];
    do
       sleep 3  # Wait for OpenVPN to initialize and have had time to write the pid file
       grep "Initialization Sequence Completed" $LOGDIR/$SUF:openvpn.log >/dev/null
       if [ $? -eq 0 ]; then
           ovpn_init_check=0
           ovpn_init_success=1
       fi
       ovpn_init_check=$(( $ovpn_init_check - 1 ))
    done

    opid=`cat $pidfile`
    if [ -n "$opid" ]; then
        echo "  OpenVPN running with PID $opid"
    else
        echo "  Could not read OpenVPN PID file" >&2
    fi

    # If OpenVPN did not start
    if [ $ovpn_init_success -ne 1 -o -z "$opid" ]; then
        echo "$0:  OpenVPN did not initialize in a reasonable time" >&2
        if [ -n "$opid" ]; then
           $RUN_SUDO $KILL_EXEC $opid
        fi
        $RUN_SUDO $KILL_EXEC $sudopid
	echo "tail -5 $SUF:openvpn.log" >&2
	tail -5 $LOGDIR/$SUF:openvpn.log >&2
	echo -e "\nFAIL. skip rest of sub-tests for test run $SUF.\n" >&2
	trap - 0 1 2 3 15
	SUMMARY_FAIL="$SUMMARY_FAIL $SUF"
	exit_code=30
	continue
    fi

    # make sure openvpn client is terminated in case shell exits
    trap "$RUN_SUDO $KILL_EXEC $opid" 0
    trap "$RUN_SUDO $KILL_EXEC $opid ; trap - 0 ; exit 1" 1 2 3 15

    # compare whether anything changed in ifconfig/route setup?
    echo "save ifconfig+route"
    get_ifconfig_route >$LOGDIR/$SUF:ifconfig_route.txt

    echo -n "compare pre-openvpn ifconfig+route with current values..."
    if diff $LOGDIR/$SUF:ifconfig_route_pre.txt \
	    $LOGDIR/$SUF:ifconfig_route.txt >/dev/null
    then
	fail "no differences between ifconfig/route before OpenVPN start and now."
    else
	echo -e " OK!\n"
    fi

    # post init script needed?
    if [ -n "$test_postinit" ]; then
        echo -e "running post-init cmd: '$test_postinit'"
        eval $test_postinit
    fi

    # expected ifconfig values in there?
    check_ifconfig 4 "$expect_ifconfig4"
    check_ifconfig 6 "$expect_ifconfig6"

    run_ping_tests 4 want_ok "$ping4_hosts"
    run_ping_tests 6 want_ok "$ping6_hosts"
    echo -e "ping tests done.\n"

    echo "stopping OpenVPN"
    $RUN_SUDO $KILL_EXEC $opid
    wait $!
    rc=$?
    if [ $rc != 0 ] ; then
	fail "OpenVPN return code $rc, expect 0"
    fi

    echo -e "\nsave post-openvpn ifconfig + route..."
    get_ifconfig_route >$LOGDIR/$SUF:ifconfig_route_post.txt

    echo -n "compare pre- and post-openvpn ifconfig + route..."
    if diff $LOGDIR/$SUF:ifconfig_route_pre.txt \
	    $LOGDIR/$SUF:ifconfig_route_post.txt >$LOGDIR/$SUF:ifconfig_route_diff.txt
    then
	echo -e " OK.\n"
    else
	cat $LOGDIR/$SUF:ifconfig_route_diff.txt >&2
	fail "differences between pre- and post-ifconfig/route"
    fi
    if [ "$fail_count" = 0 ] ; then
        echo -e "test run $SUF: all tests OK.\n"
	SUMMARY_OK="$SUMMARY_OK $SUF"
    else
	echo -e "test run $SUF: $fail_count test failures. FAIL.\n";
	SUMMARY_FAIL="$SUMMARY_FAIL $SUF"
	exit_code=30
    fi

    if [ -n "$test_cleanup" ]; then
        echo -e "cleaning up: '$test_cleanup'"
        eval $test_cleanup
    fi

done

if [ -z "$SUMMARY_OK" ] ; then SUMMARY_OK=" none"; fi
if [ -z "$SUMMARY_FAIL" ] ; then SUMMARY_FAIL=" none"; fi
echo "Test sets succeded:$SUMMARY_OK."
echo "Test sets failed:$SUMMARY_FAIL."

# remove trap handler
trap - 0 1 2 3 15
exit $exit_code
