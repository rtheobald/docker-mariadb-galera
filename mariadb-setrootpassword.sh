#!/bin/bash

set -u

MSA=/usr/bin/mysqladmin
# generate long random password
MARIADB_ROOT_PW=$(openssl rand -base64 32)


# make sure ownership of data dir is OK
chown -R mysql:mysql /var/lib/mysql
/usr/bin/mysqld_safe &



sleep 5 # wait for mysqld_safe to rev up, and check for port 3306
port_open=0

while [ "$port_open" -eq 0 ]; do
   /bin/nc -z -w 5 127.0.0.1 43775
   if [ $? -ne 0 ]; then
       echo "Sleeping waiting for port 43775 to open: result " $? 
       sleep 1
   else
       echo "Port 43775 is open"
       port_open=1
   fi
done

# Secure the installation
done=0
count=0
maxtries=10
while [ $done -eq 0 ]; do
    ${MSA} -u root password ${MARIADB_ROOT_PW}
    if [ $? -ne 0 ]; then
        count=$((${count} + 1))
        if [ $count -gt $maxtries ]; then
            echo "Maximum tries at setting password exceeded. Giving up"
            exit 1
        else
            echo "Root password set failed. Sleeping, then retrying"
            sleep 1
        fi
    else
        echo "Root Password set successfully"
        done=1
    fi
done

# this code mimics the secure install script, which was originally
# scripted via expect. I found that unreliable, hence this section

# drop test database
echo "Dropping test DB"
DROP="DROP DATABASE IF EXISTS test"
echo "$DROP" | mysql -u root --password="$MARIADB_ROOT_PW" mysql

echo "Cleaning test db privs"
# remove db privs for test
DELETE="DELETE FROM mysql.db Where Db='test' OR Db='test\\_%'"
echo "$DELETE" | mysql -u root --password="$MARIADB_ROOT_PW" mysql

echo "Deleting anon db users"
# remove anon users
DELETE="DELETE FROM mysql.user WHERE User=''"
echo "$DELETE" | mysql -u root --password="$MARIADB_ROOT_PW" mysql

echo "create mysql user"
# create mysql@localhost user for xtrabackup
CUSER="CREATE USER 'mysql'@'localhost'"
echo "$CUSER" | mysql -u root --password="$MARIADB_ROOT_PW" mysql

# now set the root passwords given the certificates available
ROOTCERTS=/etc/ssl/mysql/root
if [ -d ${ROOTCERTS} ]; then
    clist=$(find ${ROOTCERTS} -type f -a -name \*.pem -print)

    if [ -z "${clist}" ]; then
        echo "No certificates available to encrypt root pw" >&2
        exit 1
    fi

    # dumping encrypted root password to disk - make sure that
    # only owner can read/write it
    oldu=$(umask)
    umask 0077
    echo -n $MARIADB_ROOT_PW | openssl smime -encrypt -aes256 \
      -out /var/lib/mysql/rootpw.pem \
      ${clist}
    umask ${oldu}

    for c in ${clist}; do
        filename=$(basename "${c}")
        username=${filename%.*}
        # extract subject and issuer
        subject=$(openssl x509 -noout -subject -in ${c} | sed -e "s/^subject= //ig")
        printf -v qsubject "%q" "${subject}"
        issuer=$(openssl x509 -noout -issuer -in ${c} | sed -e "s/^issuer= //ig" -e "")
        printf -v qissuer "%q" "${issuer}"
        CUSER="CREATE USER '${username}'@'%'"
        echo "${CUSER}" | mysql -u root --password="$MARIADB_ROOT_PW" mysql
        GRANT="GRANT ALL PRIVILEGES ON *.* TO '${username}'@'%' \
               REQUIRE SUBJECT '${qsubject}' AND \
               ISSUER '${qissuer}' \
               WITH GRANT OPTION"
        echo "${GRANT}" | mysql -u root --password="$MARIADB_ROOT_PW" mysql
   done
fi
echo "FLUSH PRIVILEGES" | mysql -u root --password="$MARIADB_ROOT_PW" mysql

echo "Shutting down MySQL server"
${MSA} -uroot -p${MARIADB_ROOT_PW} shutdown
echo "---> MariaDB installation secured with root password" >&2
