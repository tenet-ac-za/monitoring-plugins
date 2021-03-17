#!/bin/bash
# @author Guy Halse http://orcid.org/0000-0002-9388-8592
# @copyright Copyright (c) 2021, Tertiary Education and Research Network of South Africa NPC
# @license https://github.com/tenet-ac-za/monitoring-plugins/blob/master/LICENSE MIT License

source "${OMD_ROOT}/lib/monitoring-plugins/utils.sh"

function usage()
{
  echo "# this is a wrapper around ike-scan to test IKEv2 VPNNs
# https://github.com/royhills/ike-scan

Parameters :
-H <address> - Address of VPN server
-l <path> - Location of ike-scan (if not in PATH)
-d <dhgroup> - DH group (defaults to 14)
-t <seconds> - timeout in seconds
-v - verbose output
" >&2
  exit ${STATE_UNKNOWN}
}

IKESCAN_PROG=$(which ike-scan)
VERBOSE=0
TIMEOUT=5
DHGROUP=14

while getopts "H:d:l:t:v" opt
do
  case "$opt" in
    H) ADDRESS=$OPTARG;;
	d) DHGROUP=$OPTARG;;
    l) IKESCAN_PROG=$OPTARG;;
	t) TIMEOUT=$OPTARG;;
	v) VERBOSE=1;;
    h) usage;;
    \?) usage;;
  esac
done
shift $((OPTIND-1))

if [[ ! -e "${IKESCAN_PROG}" ]]; then
  echo "ike-scan program \"${IKESCAN_PROG}\" not found"
  exit ${STATE_UNKNOWN}
fi
if [[ ! -x "${IKESCAN_PROG}" ]]; then
  echo "ike-scan program \"${IKESCAN_PROG}\" not executable"
  exit ${STATE_UNKNOWN}
fi

if [[ -z "$ADDRESS" ]]; then
  echo "Address of VPN server is not specified. (option -H)"
  exit ${STATE_UNKNOWN}
fi

# timeout in ms
TIMEOUT=$(( ${TIMEOUT} * 1000 ))

BEGIN=$(date +%s.%N)
OUT=$(${IKESCAN_PROG} --sport=0 --ikev2 --dhgroup=${DHGROUP} --timeout=${TIMEOUT} ${ADDRESS})
IKESCAN_PROG_RETCODE=$? 
END=$(date +%s.%N)

if [[ ${VERBOSE} -gt 0 ]] ; then
  echo "----"
  echo "$OUT"
  echo "----"
fi

if [[ $IKESCAN_PROG_RETCODE -ne 0 ]] ; then
  echo "ike-scan returned $IKESCAN_PROG_RETCODE"
  echo "${OUT}"
  ret=${STATE_UNKNOWN}

elif [[ "${OUT}" =~ "1 returned handshake" ]] ; then
  echo "${OUT}" | awk -F '\t' '/^([0-9]{1,3}\.){3}[0-9]{1,3}/ { print $2 }'
  ret=${STATE_OK}

elif [[ "${OUT}" =~ "1 returned notify" ]] ; then
  echo "${OUT}" | awk -F '\t' '/^([0-9]{1,3}\.){3}[0-9]{1,3}/ { print $2 }'
  ret=${STATE_WARNING}

elif [[ "${OUT}" =~ "1 hosts scanned in" ]] ; then
  echo "ERROR: failed to complete IKEv2 handshake"
  ret=${STATE_ERROR}

else
  echo ${OUT}
  ret=${STATE_UNKNOWN}
fi

printf "|rtt=%0.0fms;;;0;%d\n" $(echo "( $END - $BEGIN ) * 1000" | bc) ${TIMEOUT}
exit ${ret}
