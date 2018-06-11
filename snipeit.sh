#!/bin/bash
#/ Usage: sniepit [-vh]
#/
#/ Install Snipe-IT open source asset management.
#/
#/ OPTIONS:
#/   -v | --verbose    Enable verbose output.
#/   -h | --help       Show this message.

######################################################
#           Snipe-It Install Script                  #
#          Script created by Mike Tucker             #
#            mtucker6784@gmail.com                   #
#                                                    #
# Feel free to modify, but please give               #
# credit where it's due. Thanks!                     #
######################################################

# Parse arguments
while true; do
  case "$1" in
    -h|--help)
      show_help=true
      shift
      ;;
    -v|--verbose)
      set -x
      verbose=true
      shift
      ;;
    -*)
      echo "Error: invalid argument: '$1'" 1>&2
      exit 1
      ;;
    *)
      break
      ;;
  esac
done

print_usage () {
  grep '^#/' <"$0" | cut -c 4-
  exit 1
}

if [ -n "$show_help" ]; then
  print_usage
else
  for x in "$@"; do
    if [ "$x" = "--help" ] || [ "$x" = "-h" ]; then
      print_usage
    fi
  done
fi

# ensure running as root
if [ "$(id -u)" != "0" ]; then
    #Debian doesnt have sudo if root has a password.
    if ! hash sudo 2>/dev/null; then
        exec su -c "$0" "$@"
    else
        exec sudo "$0" "$@"
    fi
fi

#First things first, let's set some variables and find our distro.
clear

name="snipeit"
user="snipeitapp"
webdir="/var/www"
hostname="$(hostname)"
fqdn="$(hostname --fqdn)"

progress () {
  spin[0]="-"
  spin[1]="\\"
  spin[2]="|"
  spin[3]="/"
  
  echo -n " "
  while kill -0 "$pid" > /dev/null 2>&1; do
    for i in "${spin[@]}"; do
      echo -ne "\\b$i"
      sleep .1
    done
  done
  echo ""
}

log () {
  if [ -n "$verbose" ]; then
    eval "$@" |& tee -a /var/log/snipeit-install.log
  else
    eval "$@" |& tee -a /var/log/snipeit-install.log >/dev/null 2>&1
  fi
}

install_packages () {
  case $distro in
    ubuntu|debian)
      for p in $PACKAGES; do
        if dpkg -s "$p" >/dev/null 2>&1; then
          echo "  * $p already installed"
        else
          echo "  * Installing $p"
          log "DEBIAN_FRONTEND=noninteractive apt-get install -y $p"
        fi
      done;
      ;;
    centos)
      for p in $PACKAGES; do
        if yum list installed "$p" >/dev/null 2>&1; then
          echo "  * $p already installed"
        else
          echo "  * Installing $p"
          log "yum -y install $p"
        fi
      done;
      ;;
    fedora)
      for p in $PACKAGES; do
        if dnf list installed "$p" >/dev/null 2>&1; then
          echo "  * $p already installed"
        else
          echo "  * Installing $p"
          log "dnf -y install $p"
        fi
      done;
      ;;
  esac
}

create_virtualhost () {
  {
    echo "<VirtualHost *:80>"
    echo "  <Directory $webdir/$name/public>"
    echo "      Allow From All"
    echo "      AllowOverride All"
    echo "      Options +Indexes"
    echo "  </Directory>"
    echo ""
    echo "  DocumentRoot $webdir/$name/public"
    echo "  ServerName $fqdn"
    echo "</VirtualHost>"
  } >> "$apachefile"
}

run_as () {
  if ! hash sudo 2>/dev/null; then
      su -c "$@" $user
  else
      sudo -u $user "$@"
  fi
}

install_composer () {
  # https://getcomposer.org/doc/faqs/how-to-install-composer-programmatically.md
  EXPECTED_SIGNATURE="$(wget -q -O - https://composer.github.io/installer.sig)"
  php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
  ACTUAL_SIGNATURE="$(php -r "echo hash_file('SHA384', 'composer-setup.php');")"

  if [ "$EXPECTED_SIGNATURE" != "$ACTUAL_SIGNATURE" ]
  then
      >&2 echo 'ERROR: Invalid composer installer signature'
      rm composer-setup.php
      exit 1
  fi

  php composer-setup.php --install-dir "$webdir/$name/"
  rm composer-setup.php
}

install_snipeit () {
  echo "* Creating Snipe-IT user."
  useradd "$user"
  usermod -a -G "$apache_group" "$user"

  echo "* Creating MariaDB Database/User."
  echo "* Please Input your MariaDB root password:"
  mysql -u root -p --execute="CREATE DATABASE snipeit;GRANT ALL PRIVILEGES ON snipeit.* TO snipeit@localhost IDENTIFIED BY '$mysqluserpw';"

  echo "* Cloning Snipe-IT from github to the web directory."
  log "git clone https://github.com/snipe/snipe-it $webdir/$name"

  echo "* Configuring .env file."
  cp "$webdir/$name/.env.example" "$webdir/$name/.env"

  #TODO escape SED delimiter in variables
  sed -i '1 i\#Created By Snipe-it Installer' "$webdir/$name/.env"
  sed -i "s|^\\(APP_TIMEZONE=\\).*|\\1$tzone|" "$webdir/$name/.env"
  sed -i "s|^\\(DB_HOST=\\).*|\\1localhost|" "$webdir/$name/.env"
  sed -i "s|^\\(DB_DATABASE=\\).*|\\1snipeit|" "$webdir/$name/.env"
  sed -i "s|^\\(DB_USERNAME=\\).*|\\1snipeit|" "$webdir/$name/.env"
  sed -i "s|^\\(DB_PASSWORD=\\).*|\\1$mysqluserpw|" "$webdir/$name/.env"
  sed -i "s|^\\(APP_URL=\\).*|\\1http://$fqdn|" "$webdir/$name/.env"

  echo "* Installing composer."
  install_composer

  echo "* Setting permissions."
  for chmod_dir in "$webdir/$name/storage" "$webdir/$name/storage/private_uploads" "$webdir/$name/public/uploads"; do
    chmod -R 755 "$chmod_dir"
  done

  chown -R "$user":"$apache_group" "$webdir/$name"

  echo "* Running composer."  
  run_as php "$webdir/$name"/composer.phar install --no-dev --prefer-source --working-dir "$webdir/$name/"

  echo "* Generating the application key."
  log "php $webdir/$name/artisan key:generate --force"

  echo "* Artisan Migrate."
  log "php $webdir/$name/artisan migrate --force"

  echo "* Creating scheduler cron."
  (crontab -l ; echo "* * * * * /usr/bin/php $webdir/$name/artisan schedule:run >> /dev/null 2>&1") | crontab -
}

set_firewall () {
  if [ "$(firewall-cmd --state)" == "running" ]; then
    echo "* Configuring firewall to allow HTTP traffic only."
    log "firewall-cmd --zone=public --add-port=http/tcp --permanent"
    log "firewall-cmd --reload"
  fi
}

set_selinux () {
  #Check if SELinux is enforcing
  if [ "$(getenforce)" == "Enforcing" ]; then
    echo "* Configuring SELinux."
    #Required for ldap integration
    setsebool -P httpd_can_connect_ldap on
    #Sets SELinux context type so that scripts running in the web server process are allowed read/write access
    chcon -R -h -t httpd_sys_script_rw_t "$webdir/$name/"
  fi
}

set_hosts () {
  echo "* Setting up hosts file."
  echo >> /etc/hosts "127.0.0.1 $hostname $fqdn"
}

if [[ -f /etc/lsb-release || -f /etc/debian_version ]]; then
  distro="$(lsb_release -is)"
  version="$(lsb_release -rs)"
  codename="$(lsb_release -cs)"
elif [ -f /etc/os-release ]; then
  distro="$(. /etc/os-release && echo $ID)"
  version="$(. /etc/os-release && echo $VERSION_ID)"
  #Order is important here.  If /etc/os-release and /etc/centos-release exist, we're on centos 7.
  #If only /etc/centos-release exist, we're on centos6(or earlier).  Centos-release is less parsable,
  #so lets assume that it's version 6 (Plus, who would be doing a new install of anything on centos5 at this point..)
  #/etc/os-release properly detects fedora
elif [ -f /etc/centos-release ]; then
  distro="Centos"
  version="6"
else
  distro="unsupported"
fi

echo "
       _____       _                  __________
      / ___/____  (_)___  ___        /  _/_  __/
      \__ \/ __ \/ / __ \/ _ \______ / /  / /
     ___/ / / / / / /_/ /  __/_____// /  / /
    /____/_/ /_/_/ .___/\___/     /___/ /_/
                /_/
"

echo ""
echo "  Welcome to Snipe-IT Inventory Installer for CentOS, Fedora, Debian and Ubuntu!"
echo ""
shopt -s nocasematch
case $distro in
  *ubuntu*)
    echo "  The installer has detected $distro version $version codename $codename."
    distro=ubuntu
    ;;
  *debian*)
    echo "  The installer has detected $distro version $version codename $codename."
    distro=debian
    ;;
  *centos*|*redhat*|*ol*|*rhel*)
    echo "  The installer has detected $distro version $version."
    distro=centos
    ;;
  *fedora*)
    echo "  The installer has detected $distro version $version."
    distro=fedora
    ;;
  *)
    echo "  The installer was unable to determine your OS. Exiting for safety."
    exit 1
    ;;
esac
shopt -u nocasematch

echo -n "  Q. What is the FQDN of your server? ($fqdn): "
read -r fqdn
if [ -z "$fqdn" ]; then
  fqdn="$(hostname --fqdn)"
fi
echo "     Setting to $fqdn"
echo ""

ans=default
until [[ $ans == "yes" ]] || [[ $ans == "no" ]]; do
echo -n "  Q. Do you want to automatically create the database user password? (y/n) "
read -r setpw

case $setpw in
  [yY] | [yY][Ee][Ss] )
    mysqluserpw="$(< /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c16; echo)"
    echo ""
    ans="yes"
    ;;
  [nN] | [n|N][O|o] )
    echo -n  "  Q. What do you want your snipeit user password to be?"
    read -rs mysqluserpw
    echo ""
    ans="no"
    ;;
  *)  echo "  Invalid answer. Please type y or n"
    ;;
esac
done

case $distro in
  debian)
  if [[ "$version" =~ ^9 ]]; then
    # Install for Debian 9.x
    apache_group=www-data
    tzone=$(cat /etc/timezone)
    apachefile=/etc/apache2/sites-available/$name.conf

    echo "* Adding PHP repository."
    log "apt-get install -y apt-transport-https"
    log "wget -O /etc/apt/trusted.gpg.d/php.gpg https://packages.sury.org/php/apt.gpg"
    echo "deb https://packages.sury.org/php/ $codename main" > /etc/apt/sources.list.d/php.list

    echo -n "* Updating installed packages."
    log "apt-get update && apt-get -y upgrade" & pid=$!
    progress

    echo "* Installing Apache httpd, PHP, MariaDB and other requirements."
    PACKAGES="mariadb-server mariadb-client apache2 libapache2-mod-php7.1 php7.1 php7.1-mcrypt php7.1-curl php7.1-mysql php7.1-gd php7.1-ldap php7.1-zip php7.1-mbstring php7.1-xml php7.1-bcmath curl git unzip"
    install_packages

    echo "* Configuring Apache."
    create_virtualhost
    log "a2enmod rewrite"
    log "a2ensite $name.conf"

    set_hosts

    echo "* Securing MariaDB."
    /usr/bin/mysql_secure_installation

    install_snipeit

    echo "* Restarting Apache httpd."
    log "service apache2 restart"
  elif [[ "$version" =~ ^8 ]]; then
    # Install for Debian 8.x
    apache_group=www-data
    tzone=$(cat /etc/timezone)
    apachefile=/etc/apache2/sites-available/$name.conf

    echo "* Adding MariaDB and ppa:ondrej/php repositories."
    log "apt-get install -y software-properties-common apt-transport-https"
    log "apt-key adv --recv-keys --keyserver hkp://keyserver.ubuntu.com:80 0xcbcb082a1bb943db"
    log "add-apt-repository 'deb [arch=amd64,i386,ppc64el] http://nyc2.mirrors.digitalocean.com/mariadb/repo/10.1/debian $codename main'"
    log "wget -O /etc/apt/trusted.gpg.d/php.gpg https://packages.sury.org/php/apt.gpg"
    echo "deb https://packages.sury.org/php/ $codename main" > /etc/apt/sources.list.d/php.list

    echo -n "* Updating installed packages."
    log "apt-get update && apt-get -y upgrade" & pid=$!
    progress

    echo "* Installing Apache httpd, PHP, MariaDB and other requirements."
    PACKAGES="mariadb-server mariadb-client php7.1 php7.1-mcrypt php7.1-curl php7.1-mysql php7.1-gd php7.1-ldap php7.1-zip php7.1-mbstring php7.1-xml php7.1-bcmath curl git unzip"
    install_packages

    echo "* Configuring Apache."
    create_virtualhost
    log "a2enmod rewrite"
    log "a2ensite $name.conf"

    set_hosts

    echo "* Securing MariaDB."
    /usr/bin/mysql_secure_installation

    install_snipeit

    echo "* Restarting Apache httpd."
    log "service apache2 restart"
  else
    echo "Unsupported Debian version. Version found: $version"
    exit 1
  fi
  ;;
  ubuntu)
  if [ "$version" == "18.04" ]; then
    # Install for Ubuntu 18.04
    apache_group=www-data
    tzone=$(cat /etc/timezone)
    apachefile=/etc/apache2/sites-available/$name.conf

    echo -n "* Updating installed packages."
    log "apt-get update && DEBIAN_FRONTEND=noninteractive apt-get -y upgrade" & pid=$!
    progress

    echo "* Installing Apache httpd, PHP, MariaDB and other requirements."
    PACKAGES="mariadb-server mariadb-client apache2 libapache2-mod-php php php-mcrypt php-curl php-mysql php-gd php-ldap php-zip php-mbstring php-xml php-bcmath curl git unzip"
    install_packages

    echo "* Configuring Apache."
    create_virtualhost
    log "phpenmod mcrypt"
    log "phpenmod mbstring"
    log "a2enmod rewrite"
    log "a2ensite $name.conf"

    set_hosts

    echo "* Starting MariaDB."
    log "systemctl start mariadb.service"

    echo "* Securing MariaDB."
    /usr/bin/mysql_secure_installation

    install_snipeit

    echo "* Restarting Apache httpd."
    log "systemctl restart apache2"
  elif [ "$version" == "16.04" ]; then
    # Install for Ubuntu 16.04
    apache_group=www-data
    tzone=$(cat /etc/timezone)
    apachefile=/etc/apache2/sites-available/$name.conf

    echo "* Adding MariaDB and ppa:ondrej/php repositories."
    log "apt-get install -y software-properties-common"
    log "apt-key adv --recv-keys --keyserver hkp://keyserver.ubuntu.com:80 0xF1656F24C74CD1D8"
    log "add-apt-repository 'deb [arch=amd64,i386] http://nyc2.mirrors.digitalocean.com/mariadb/repo/10.1/ubuntu $codename main'"
    log "add-apt-repository -y ppa:ondrej/php"

    echo -n "* Updating installed packages."
    log "apt-get update && DEBIAN_FRONTEND=noninteractive apt-get -y upgrade" & pid=$!
    progress

    echo "* Installing Apache httpd, PHP, MariaDB and other requirements."
    PACKAGES="mariadb-server mariadb-client apache2 libapache2-mod-php7.1 php7.1 php7.1-mcrypt php7.1-curl php7.1-mysql php7.1-gd php7.1-ldap php7.1-zip php7.1-mbstring php7.1-xml php7.1-bcmath curl git unzip"
    install_packages

    echo "* Configuring Apache."
    create_virtualhost
    log "phpenmod mcrypt"
    log "phpenmod mbstring"
    log "a2enmod rewrite"
    log "a2ensite $name.conf"

    set_hosts

    echo "* Starting MariaDB."
    log "service mysql start"

    echo "* Securing MariaDB."
    /usr/bin/mysql_secure_installation

    install_snipeit

    echo "* Restarting Apache httpd."
    log "service apache2 restart"
  elif [ "$version" == "14.04" ]; then
    # Install for Ubuntu 14.04
    apache_group=www-data
    tzone=$(cat /etc/timezone)
    apachefile=/etc/apache2/sites-available/$name.conf

    echo "* Adding MariaDB and ppa:ondrej/php repositories."
    log "apt-get install -y software-properties-common"
    log "apt-key adv --recv-keys --keyserver hkp://keyserver.ubuntu.com:80 0xcbcb082a1bb943db"
    log "add-apt-repository 'deb [arch=amd64,i386,ppc64el] http://nyc2.mirrors.digitalocean.com/mariadb/repo/10.1/ubuntu $codename main'"
    log "add-apt-repository ppa:ondrej/php -y"

    echo -n "* Updating installed packages."
    log "apt-get update && DEBIAN_FRONTEND=noninteractive apt-get -y upgrade" & pid=$!
    progress

    echo "* Installing Apache httpd, PHP, MariaDB and other requirements."
    PACKAGES="mariadb-server mariadb-client php7.1 php7.1-mcrypt php7.1-curl php7.1-mysql php7.1-gd php7.1-ldap php7.1-zip php7.1-mbstring php7.1-xml php7.1-bcmath curl git unzip"
    install_packages

    echo "* Configuring Apache."
    create_virtualhost
    log "phpenmod mcrypt"
    log "phpenmod mbstring"
    log "a2enmod rewrite"
    log "a2ensite $name.conf"

    set_hosts

    echo "* Starting MariaDB."
    log "service mysql start"

    echo "* Securing MariaDB."
    /usr/bin/mysql_secure_installation

    install_snipeit

    echo "* Restarting Apache httpd."
    log "service apache2 restart"
  else
    echo "Unsupported Ubuntu version. Version found: $version"
    exit 1
  fi
  ;;
  centos)
  if [[ "$version" =~ ^6 ]]; then
    # Install for CentOS/Redhat 6.x
    apache_group=apache
    tzone=$(grep ZONE /etc/sysconfig/clock | tr -d '"' | sed 's/ZONE=//g');
    apachefile=/etc/httpd/conf.d/$name.conf

    echo "* Adding IUS, epel-release and MariaDB repositories."
    mariadbRepo=/etc/yum.repos.d/MariaDB.repo
    touch "$mariadbRepo"
    {
        echo "[mariadb]"
        echo "name = MariaDB"
        echo "baseurl = http://yum.mariadb.org/10.0/centos6-amd64"
        echo "gpgkey=https://yum.mariadb.org/RPM-GPG-KEY-MariaDB"
        echo "gpgcheck=1"
        echo "enable=1"
    } >> "$mariadbRepo"

    log "yum -y install wget epel-release"
    log "yum -y install https://centos6.iuscommunity.org/ius-release.rpm"
    log "rpm --import /etc/pki/rpm-gpg/IUS-COMMUNITY-GPG-KEY"

    echo "* Installing Apache httpd, PHP, MariaDB and other requirements."
    PACKAGES="httpd mariadb-server git unzip php71u php71u-mysqlnd php71u-bcmath php71u-cli php71u-common php71u-embedded php71u-gd php71u-mbstring php71u-mcrypt php71u-ldap php71u-json php71u-simplexml php71u-process"
    install_packages

    echo "* Configuring Apache."
    create_virtualhost

    echo "* Setting MariaDB to start on boot and starting MariaDB."
    log "chkconfig mysql on"
    log "/sbin/service mysql start"

    set_hosts

    echo "* Securing MariaDB."
    /usr/bin/mysql_secure_installation

    install_snipeit

    if /sbin/service iptables status >/dev/null 2>&1; then
        echo "* Configuring iptables."
        iptables -I INPUT 1 -p tcp -m tcp --dport 80 -j ACCEPT
        iptables -I INPUT 1 -p tcp -m tcp --dport 443 -j ACCEPT
        service iptables save
    fi

    echo "* Setting Apache httpd to start on boot and starting service."
    log "chkconfig httpd on"
    log "/sbin/service httpd start"
  elif [[ "$version" =~ ^7 ]]; then
    # Install for CentOS/Redhat 7
    apache_group=apache
    tzone=$(timedatectl | gawk -F'[: ]' ' $9 ~ /zone/ {print $11}');
    apachefile=/etc/httpd/conf.d/$name.conf

    echo "* Adding IUS, epel-release and MariaDB repositories."
    log "yum -y install wget epel-release"
    log "yum -y install https://centos7.iuscommunity.org/ius-release.rpm"
    log "rpm --import /etc/pki/rpm-gpg/IUS-COMMUNITY-GPG-KEY"

    echo "* Installing Apache httpd, PHP, MariaDB and other requirements."
    PACKAGES="httpd mariadb-server git unzip php71u php71u-mysqlnd php71u-bcmath php71u-cli php71u-common php71u-embedded php71u-gd php71u-mbstring php71u-mcrypt php71u-ldap php71u-json php71u-simplexml php71u-process"
    install_packages

    echo "* Configuring Apache."
    create_virtualhost

    set_hosts

    echo "* Setting MariaDB to start on boot and starting MariaDB."
    log "systemctl enable mariadb.service"
    log "systemctl start mariadb.service"

    echo "* Securing MariaDB."
    /usr/bin/mysql_secure_installation

    install_snipeit

    set_firewall

    set_selinux

    echo "* Setting Apache httpd to start on boot and starting service."
    log "systemctl enable httpd.service"
    log "systemctl restart httpd.service"
  else
    echo "Unsupported CentOS version. Version found: $version"
    exit 1
  fi
  ;;
  fedora)
  if [ "$version" -ge 26 ]; then
    # Install for Fedora 26+
    apache_group=apache
    tzone=$(timedatectl | gawk -F'[: ]' ' $9 ~ /zone/ {print $11}');
    apachefile=/etc/httpd/conf.d/$name.conf

    echo "* Installing Apache httpd, PHP, MariaDB and other requirements."
    PACKAGES="httpd mariadb-server git unzip php php-mysqlnd php-bcmath php-cli php-common php-embedded php-gd php-mbstring php-mcrypt php-ldap php-json php-simplexml"
    install_packages

    echo "* Configuring Apache."
    create_virtualhost

    set_hosts

    echo "* Setting MariaDB to start on boot and starting MariaDB."
    log "systemctl enable mariadb.service"
    log "systemctl start mariadb.service"

    echo "* Securing MariaDB."
    /usr/bin/mysql_secure_installation

    install_snipeit

    set_firewall

    set_selinux

    echo "* Setting Apache httpd to start on boot and starting service."
    log "systemctl enable httpd.service"
    log "systemctl restart httpd.service"
  else
    echo "Unsupported Fedora version. Version found: $version"
    exit 1
  fi
esac

setupmail=default
until [[ $setupmail == "yes" ]] || [[ $setupmail == "no" ]]; do
echo -n "  Q. Do you want to configure mail server settings? (y/n) "
read -r setupmail

case $setupmail in
  [yY] | [yY][Ee][Ss] )
    echo -n "  Outgoing mailserver address:"
    read -r mailhost
    sed -i "s|^\\(MAIL_HOST=\\).*|\\1$mailhost|" "$webdir/$name/.env"

    echo -n "  Server port number:"
    read -r mailport
    sed -i "s|^\\(MAIL_PORT=\\).*|\\1$mailport|" "$webdir/$name/.env"

    echo -n "  Username:"
    read -r mailusername
    sed -i "s|^\\(MAIL_USERNAME=\\).*|\\1$mailusername|" "$webdir/$name/.env"

    echo -n "  Password:"
    read -rs mailpassword
    sed -i "s|^\\(MAIL_PASSWORD=\\).*|\\1$mailpassword|" "$webdir/$name/.env"
    echo ""

    echo -n "  Encryption(null/TLS/SSL):"
    read -r mailencryption
    sed -i "s|^\\(MAIL_ENCRYPTION=\\).*|\\1$mailencryption|" "$webdir/$name/.env"

    echo -n "  From address:"
    read -r mailfromaddr
    sed -i "s|^\\(MAIL_FROM_ADDR=\\).*|\\1$mailfromaddr|" "$webdir/$name/.env"

    echo -n "  From name:"
    read -r mailfromname
    sed -i "s|^\\(MAIL_FROM_NAME=\\).*|\\1$mailfromname|" "$webdir/$name/.env"

    echo -n "  Reply to address:"
    read -r mailreplytoaddr
    sed -i "s|^\\(MAIL_REPLYTO_ADDR=\\).*|\\1$mailreplytoaddr|" "$webdir/$name/.env"

    echo -n "  Reply to name:"
    read -r mailreplytoname
    sed -i "s|^\\(MAIL_REPLYTO_NAME=\\).*|\\1$mailreplytoname|" "$webdir/$name/.env"
    setupmail="yes"
    ;;
  [nN] | [n|N][O|o] )
    setupmail="no"
    ;;
  *)  echo "  Invalid answer. Please type y or n"
    ;;
esac
done

echo ""
echo "  ***Open http://$fqdn to login to Snipe-IT.***"
echo ""
echo ""
echo "* Cleaning up..."
rm -f snipeit.sh
rm -f install.sh
echo "* Finished!"
sleep 1
