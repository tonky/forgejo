#!/usr/bin/env bash
# The OpenLDAP server upstream CI's pgsql job runs its LDAP tests against
# (data.forgejo.org/oci/forgejo-test-openldap:1), as an enve service: the same suffix,
# admin, schema (inetOrgPerson, the image's MS-AD `Group` class and openssh-lpk's
# `ldapPublicKey`), memberOf and refint overlays, Debian's default access rules, and the
# image's entries (helpers/openldap-seed.ldif).
#
#   helpers/openldap.sh start   the server, in the foreground on 127.0.0.1:$PORT
#   helpers/openldap.sh seed    load the entries once (postStart): ldapadd, as the image
#                               does, so the overlays maintain memberOf
#
# enve sets PORT and DATA_DIR. The configuration is written at every start: it names the
# store's schema files, which differ per platform.
set -euo pipefail

cd "$(dirname "$0")/.."

suffix="dc=planetexpress,dc=com"
admin="cn=admin,${suffix}"
# The image's LDAP_SECRET.
secret="GoodNewsEveryone"

start() {
    local slapd schema
    # bin/slapadd links to libexec/slapd; the schema files are the package's etc/schema.
    slapd="$(cd "$(dirname "$(command -v slapadd)")/../libexec" && pwd -P)/slapd"
    schema="$(cd "$(dirname "${slapd}")/../etc/schema" && pwd -P)"
    mkdir -p "${DATA_DIR}/db"
    cat > "${DATA_DIR}/slapd.conf" <<EOF
include ${schema}/core.schema
include ${schema}/cosine.schema
include ${schema}/nis.schema
include ${schema}/inetorgperson.schema

# The image's msad.ldif: groups are MS-AD style.
attributetype ( 1.2.840.113556.1.4.750 NAME 'groupType'
    SYNTAX 1.3.6.1.4.1.1466.115.121.1.27 SINGLE-VALUE )
objectclass ( 1.2.840.113556.1.5.8 NAME 'Group' DESC 'a group of users'
    SUP top STRUCTURAL MUST ( groupType \$ cn ) MAY ( member ) )

# The image's openssh_lpk.ldif: the SSH key sync test reads sshPublicKey.
attributetype ( 1.3.6.1.4.1.24552.500.1.1.1.13 NAME 'sshPublicKey'
    DESC 'MANDATORY: OpenSSH Public key' EQUALITY octetStringMatch
    SYNTAX 1.3.6.1.4.1.1466.115.121.1.40 )
objectclass ( 1.3.6.1.4.1.24552.500.1.1.2.0 NAME 'ldapPublicKey'
    SUP top AUXILIARY DESC 'MANDATORY: OpenSSH LPK objectclass'
    MUST ( sshPublicKey \$ uid ) )

pidfile ${DATA_DIR}/slapd.pid
argsfile ${DATA_DIR}/slapd.args

database mdb
maxsize 268435456
suffix "${suffix}"
rootdn "${admin}"
rootpw ${secret}
directory ${DATA_DIR}/db
index objectClass eq
index uid eq
index member,memberOf eq

# Debian's slapd defaults, which the image keeps.
access to attrs=userPassword by self write by anonymous auth by * none
access to attrs=shadowLastChange by self write by * read
access to * by * read

# The image's memberof.ldif.
overlay memberof
memberof-group-oc Group
memberof-member-ad member
memberof-memberof-ad memberOf
memberof-dangling ignore
memberof-refint TRUE

overlay refint
refint_attributes owner manager uniqueMember member memberOf
EOF
    # The image's limit: slapd preallocates per descriptor.
    ulimit -n 1024 2>/dev/null || true
    # -d keeps it in the foreground; 256 logs connections and operations, as the image does.
    exec "${slapd}" -f "${DATA_DIR}/slapd.conf" -h "ldap://127.0.0.1:${PORT}/" -d 256
}

seed() {
    local url="ldap://127.0.0.1:${PORT}"
    # The last entry the seed adds: once it's there, so is the rest.
    local last="cn=git,ou=people,${suffix}"
    if ldapsearch -x -LLL -H "${url}" -b "${last}" -s base dn >/dev/null 2>&1; then
        return 0
    fi
    # -c: entries an interrupted seed already added stay.
    ldapadd -c -x -H "${url}" -D "${admin}" -w "${secret}" -f helpers/openldap-seed.ldif >/dev/null || true
    ldapsearch -x -LLL -H "${url}" -b "${last}" -s base dn >/dev/null || {
        echo "openldap: the seed didn't load (${last} is missing)" >&2
        exit 1
    }
}

case "${1:-}" in
    start) start ;;
    seed) seed ;;
    *) echo "usage: helpers/openldap.sh <start|seed>" >&2; exit 2 ;;
esac
