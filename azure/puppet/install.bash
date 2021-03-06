#! /bin/bash
set -u
set -e

# Some utility functions.
fail() { echo >&2 "$@"; exit 1; }
cmd()  { hash "$1" >&/dev/null; } # portable 'which'
getHTTPCode () { curl -kL --write-out %{http_code} --silent --output /dev/null $1; }

##############################################################################
# We need to know what the PE platform tag is for this node, which requires
# digging through a bunch of data to extract it.  This is currently the best
# mechanism available to do this, which is copied from the PE
# installer itself.
if [ -z "${PLATFORM_NAME:-""}" -o -z "${PLATFORM_RELEASE:-""}" ]; then
    # First try identifying using lsb_release.  This takes care of Ubuntu
    # (lsb-release is part of ubuntu-minimal).
    if type lsb_release > /dev/null 2>&1; then
        t_prepare_platform=`lsb_release -icr 2>&1`

        PLATFORM_NAME="$(printf "${t_prepare_platform?}" | grep -E '^Distributor ID:' | cut -s -d: -f2 | sed 's/[[:space:]]//' | tr '[[:upper:]]' '[[:lower:]]')"

        # Sanitize name for unusual platforms
        case "${PLATFORM_NAME?}" in
            redhatenterpriseserver | redhatenterpriseclient | redhatenterpriseas | redhatenterprisees | enterpriseenterpriseserver | redhatenterpriseworkstation | redhatenterprisecomputenode | oracleserver)
                PLATFORM_NAME=rhel
                ;;
            enterprise* )
                PLATFORM_NAME=centos
                ;;
            scientific | scientifics | scientificsl )
                PLATFORM_NAME=rhel
                ;;
            'suse linux' )
                PLATFORM_NAME=sles
                ;;
            amazonami )
                PLATFORM_NAME=amazon
                ;;
        esac

        # Release
        PLATFORM_RELEASE="$(printf "${t_prepare_platform?}" | grep -E '^Release:' | cut -s -d: -f2 | sed 's/[[:space:]]//g')"

        # Sanitize release for unusual platforms
        case "${PLATFORM_NAME?}" in
            centos | rhel )
                # Platform uses only number before period as the release,
                # e.g. "CentOS 5.5" is release "5"
                PLATFORM_RELEASE="$(printf "${PLATFORM_RELEASE?}" | cut -d. -f1)"
                ;;
            debian )
                # Platform uses only number before period as the release,
                # e.g. "Debian 6.0.1" is release "6"
                PLATFORM_RELEASE="$(printf "${PLATFORM_RELEASE?}" | cut -d. -f1)"
                if [ ${PLATFORM_RELEASE} = "testing" ] ; then
                    PLATFORM_RELEASE=7
                fi
                ;;
        esac
    # Test for Solaris.
    elif [ "x$(uname -s)" = "xSunOS" ]; then
        PLATFORM_NAME="solaris"
        t_platform_release="$(uname -r)"
        # JJM We get back 5.10 but we only care about the right side of the decimal.
        PLATFORM_RELEASE="${t_platform_release##*.}"
    elif [ "x$(uname -s)" = "xAIX" ] ; then
        PLATFORM_NAME="aix"
        t_platform_release="$(oslevel | cut -d'.' -f1,2)"
        PLATFORM_RELEASE="${t_platform_release}"

        # Test for RHEL variant. RHEL, CentOS, OEL
    elif [ -f /etc/redhat-release -a -r /etc/redhat-release -a -s /etc/redhat-release ]; then
        # Oracle Enterprise Linux 5.3 and higher identify the same as RHEL
        if grep -qi 'red hat enterprise' /etc/redhat-release; then
            PLATFORM_NAME=rhel
        elif grep -qi 'centos' /etc/redhat-release; then
            PLATFORM_NAME=centos
        elif grep -qi 'scientific' /etc/redhat-release; then
            PLATFORM_NAME=rhel
        fi
        # Release - take first digit after ' release ' only.
        PLATFORM_RELEASE="$(sed 's/.*\ release\ \([[:digit:]]\).*/\1/g;q' /etc/redhat-release)"
        # Test for Cumulus releases
    elif [ -r "/etc/os-release" ] && grep -E "Cumulus Linux" "/etc/os-release" &> /dev/null ; then
        PLATFORM_NAME=cumulus
        PLATFORM_RELEASE=`grep -E "VERSION_ID" "/etc/os-release" | cut -d'=' -f2 | cut -d'.' -f'1,2'`
        # Test for Debian releases
    elif [ -f /etc/debian_version -a -r /etc/debian_version -a -s /etc/debian_version ]; then
        t_prepare_platform__debian_version_file="/etc/debian_version"
        t_prepare_platform__debian_version=`cat /etc/debian_version`

        if cat "${t_prepare_platform__debian_version_file?}" | grep -E '^[[:digit:]]' > /dev/null; then
            PLATFORM_NAME=debian
            PLATFORM_RELEASE="$(printf "${t_prepare_platform__debian_version?}" | sed 's/\..*//')"
        elif cat "${t_prepare_platform__debian_version_file?}" | grep -E '^wheezy' > /dev/null; then
            PLATFORM_NAME=debian
            PLATFORM_RELEASE="7"
        fi
    elif [ -f /etc/SuSE-release -a -r /etc/SuSE-release ]; then
        t_prepare_platform__suse_version=`cat /etc/SuSE-release`

        if printf "${t_prepare_platform__suse_version?}" | grep -E 'Enterprise Server'; then
            PLATFORM_NAME=sles
            t_version=`/bin/cat /etc/SuSE-release | grep VERSION | sed 's/^VERSION = \(\d*\)/\1/' `
            t_patchlevel=`cat /etc/SuSE-release | grep PATCHLEVEL | sed 's/^PATCHLEVEL = \(\d*\)/\1/' `
            PLATFORM_RELEASE="${t_version}"
        fi
    elif [ -f /etc/system-release ]; then
        if grep -qi 'amazon linux' /etc/system-release; then
            PLATFORM_NAME=amazon
            PLATFORM_RELEASE=6
        else
            fail "$(cat /etc/system-release) is not a supported platform for Puppet Enterprise v3.2.3
                    Please visit http://links.puppetlabs.com/puppet_enterprise_${PE_LINK_VER?}_platform_support to request support for this platform."

        fi
    elif [ -z "${PLATFORM_NAME:-""}" ]; then
        fail "$(uname -s) is not a supported platform for Puppet Enterprise v3.2.3
            Please visit http://links.puppetlabs.com/puppet_enterprise_${PE_LINK_VER?}_platform_support to request support for this platform."
    fi
fi

if [ -z "${PLATFORM_NAME:-""}" -o -z "${PLATFORM_RELEASE:-""}" ]; then
    fail "Unknown platform"
fi

# Architecture
if [ -z "${PLATFORM_ARCHITECTURE:-""}" ]; then
    case "${PLATFORM_NAME?}" in
        solaris | aix )
            PLATFORM_ARCHITECTURE="$(uname -p)"
            if [ "${PLATFORM_ARCHITECTURE}" = "powerpc" ] ; then
                PLATFORM_ARCHITECTURE='power'
            fi
            ;;
        *)
            PLATFORM_ARCHITECTURE="`uname -m`"
            ;;
    esac

    case "${PLATFORM_ARCHITECTURE?}" in
        x86_64)
            case "${PLATFORM_NAME?}" in
                ubuntu | debian )
                    PLATFORM_ARCHITECTURE=amd64
                    ;;
            esac
            ;;
        i686)
            PLATFORM_ARCHITECTURE=i386
            ;;
        ppc)
            PLATFORM_ARCHITECTURE=powerpc
            ;;
    esac
fi

# Tag
if [ -z "${PLATFORM_TAG:-""}" ]; then
    case "${PLATFORM_NAME?}" in
        # Enterprise linux (centos & rhel) share the same packaging
        # Amazon linux is similar enough for our packages
        rhel | centos | amazon )
            PLATFORM_TAG="el-${PLATFORM_RELEASE?}-${PLATFORM_ARCHITECTURE?}"
            ;;
        *)
            PLATFORM_TAG="${PLATFORM_NAME?}-${PLATFORM_RELEASE?}-${PLATFORM_ARCHITECTURE?}"
            ;;
    esac
fi

# This is the end of the code copied from the upstream installer.
##############################################################################

url="https://puppet.youbora-puppet.a4.internal.cloudapp.net:8140/packages/3.2.3/${PLATFORM_TAG}.bash"

install_file=$(mktemp)
if cmd curl; then
    t_http_code=$(curl -ksLo "${install_file?}" "${url}" --write-out %{http_code} || fail "curl failed to get ${url}")
    if [ "${t_http_code?}" != '200' ]; then
        if [[ "${PLATFORM_TAG?}" =~ (el-(5|6)-(i386|x86_64))|(debian-(6|7)-(i386|amd64))|(ubuntu-(10\.04|12\.04|14\.04)-(i386|amd64))|(sles-11-(i386|x86_64))  ]]; then
            fail "The agent packages needed to support ${PLATFORM_TAG} are not present on your master. \
To add them, apply the pe_repo::platform::$(echo "${PLATFORM_TAG?}" | tr - _ | tr -dc '[:alnum:]_') class to your master node and then run Puppet. \
The required agent packages should be retrieved when puppet runs on the master, after which you can run the install.bash script again."
        else
            fail "This method of agent installation is not supported for ${PLATFORM_TAG?} in Puppet Enterprise v3.2.3
Please install using the puppet-enterprise-installer from the Puppet Enterprise v3.2.3 tarball"
        fi
        fail "curl failed to get installation materials for ${PLATFORM_TAG?} at ${url?}
Please go to the console to add necessary materials for ${PLATFORM_TAG?} if it is a supported platform"
    fi
else
    fail "Unable to download installation materials without curl"
fi

bash "${install_file?}" || fail "Error running install script ${install_file?}"

# ...and we should be good.
exit 0
