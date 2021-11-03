# SSSD, OpenLDAP и два рутера с OpenWRT 

## Наводим порядок с пользователями в домашнем зоопарке с линуксами. С централизованным хранением учётных данных. 

Схема: на двух рутерах (один, собственно, маршрутизирует траффик, а второй в роли точки доступа WiFi используется), поднимаются сервисы LDAP в режиме зеркалирования, клиентские машины настраиваются на использование аутентификации через локальные сервисы SSSD с бэкендом на LDAP. Рутеры всё время находятся онлайн, в случае нахождения клиентского устройства оффлайн используется кэш SSSD. Траффик LDAP передаётся по зашифрованному каналу. 

## План действий:

+ Создать ключи CA. Скопировать сертификат CA на клиентские ПК. Настроить на клиентах доверие к CA. 
+ Скопировать сертификат CA на рутеры. Сгенерировать ключи и подписать сертификаты для рутеров с OpenWRT. 
+ Поставить openldap и настроить конфигурацию на рутерах, запустить. Настроить режим зеркалирования между сервисами LDAP. Наполнить базу. 
+ Поставить SSSD на клиентах, настроить, запустить.

**Примечание:** все действия производились на ПК под управлением *ArchLinux*.

## 0. условные обозначения и допущения:

**PC** — клиентский ПК, на котором проводим работы по созданию **СА** (подписание сертификатов рутеров (и их же генерация по желанию)).
**PC2** — любой другой клиентский ПК.
**user** — общий непривилегированный пользователь на *PC* и *PC2*. Имеет разрешения на *sudo* и доступ по *ssh*.
**admin** — учётная запись администратора *LDAP*, *adminpass* — пароль администратора *LDAP*. Можно настроить разными на разных рутерах.
**router1** — рутер №1 (OpenWRT, ip *192.168.1.126*),  **router2** — рутер №2 (OpenWRT, ip *192.168.1.1*).

В сети действует внутренняя служба *DNS* (на **router2**), домен — *home.my*, все сетевые устройства имеют FQDN.

## 1.а. генерируем ключи CA (PC1, user):

```
sudo pacman -S easy-rsa
mkdir ~/easy-rsa
ln -s /etc/easy-rsa/[x,o]* ~/easy-rsa/
cp /etc/easy-rsa/vars ~/easy-rsa/
cd ~/easy-rsa
export EASYRSA=$(pwd)
export EASYRSA_VARS_FILE=$(pwd)/vars
nano vars (этот пункт не потребуется, если использовать значение по-умолчанию: set_var EASYRSA_DN "cn_only")
easyrsa init-pki
easyrsa build-ca nopass
```

## 1.б. регистрируем ключи СА на текущем ПК и остальных ПК (PC1, user):

```
sudo cp ~/easy-rsa/pki/ca.crt /etc/ca-certificates/trust-source/anchors/
sudo trust extract-compat
```

На остальные ПК — scp + регистрация:
```
scp ~/easy-rsa/pki/ca.crt [user@]PC2:/tmp/ca.crt
ssh [user@]PC2 "sudo mv /tmp/ca.crt /etc/ca-certificates/trust-source/anchors/"
ssh [user@]PC2 "sudo trust extract-compat"
```

## 2.а. копируем ключ СА на router1, генерируем ключ router1 и делаем запрос на его подписание СА:

```
(PC1,user): scp ~/easy-rsa/pki/ca.crt root@router1:/еtс/ssl/certs/

(router1,root):
cd /etc/ssl
openssl genrsa -out router1.key
openssl req -new -key router1.key -out router1.req -config router1ssl.cnf -extensions v3_ca
scp router1.req user@PC:/tmp/router1.req
```

## 2.б. подписываем запрос и забрасываем сертификат рутера обратно:

```
(PC1,user): 
cd ~/easy-rsa
easyrsa import-req /tmp/router1.req router1
easyrsa sign-req server router1 #-extensions v3_ca
scp ~/easy-rsa/pki/issued/router1.crt root@router1:/etc/ssl/certs/router1.crt
```

## 2.в. повторяем пункты 2.а-2.б для рутера router2.

## 2.я. примерное содержание файла router1ssl.cnf (но можно и параметрами командной строки задать):

```
[req]
distinguished_name  = req_distinguished_name
x509_extensions     = v3_req
prompt              = no
string_mask         = utf8only

[req_distinguished_name]
C                   = RU
ST                  = Svrdl
L                   = Ekb
O                   = OpenWrt
OU                  = Home Router
CN                  = router1.home.my

[v3_req]
keyUsage            = nonRepudiation, digitalSignature, keyEncipherment
extendedKeyUsage    = serverAuth
subjectAltName      = @alt_names

[alt_names]
DNS.1               = router1.home.my
IP.1                = 192.168.1.126
```

## 3.а. устанавливаем и настраиваем OpenLDAP на router1 (router1, root):

`opkg update && opkg install openldap-server libopenldap`

Правим `[vi|nano] /etc/openldap/slapd.conf`

`/etc/init.d/ldap start`

## 3.б. наполняем базу ldap (PC, user):

`ldapadd -Z -h router1.home.my -c -D "cn=admin,dc=home,dc=my" -w adminpass -f base.ldif`

## 3.в. повторяем действия пункта 3.а на рутере router2. Если всё было настроено верно, то база ldap синхронизируется с router1.

## 3.ю. содержимое slapd.conf:

```
#master ldap server config
include        /etc/openldap/schema/core.schema
include        /etc/openldap/schema/cosine.schema
include        /etc/openldap/schema/inetorgperson.schema
include        /etc/openldap/schema/nis.schema

pidfile    /var/run/slapd.pid

argsfile    /var/run/slapd.args

access to *
by dn.exact="cn=mirror,ou=Servou,dc=home,dc=my" read
by * break

access to attrs=userPassword,givenName,sn,photo
        by self write
        by anonymous auth
        by dn.base="cn=admin,dc=home,dc=my" write
        by * none

access to *
        by self read       
        by dn.base="cn=admin,dc=home,dc=my" write
        by * read

serverID 1
database mdb
suffix "dc=home,dc=my"
rootdn "cn=admin,dc=home,dc=my"
rootpw "{SSHA}---"
directory /var/openldap-data 

index   uid             pres,eq
index   cn              pres,sub,eq
index entryUUID,objectClass eq

overlay syncprov
syncprov-checkpoint 50 10
syncprov-sessionlog 50
syncrepl rid=007
provider=ldaps://router2.home.my
tls_cacert=/etc/ssl/certs/ca.crt
searchbase="dc=home,dc=my"
bindmethod=simple
binddn="cn=mirror,ou=Servou,dc=home,dc=my"
credentials="mirrorpass"
schemachecking=on
type=refreshAndPersist
retry="60 +"

mirrormode on

TLSCACertificateFile /etc/ssl/certs/ca.crt
TLSCertificateFile /etc/ssl/certs/router1.crt
TLSCertificateKeyFile /etc/ssl/private/router1.key
```

**Примечания:** для формирования хеша пароля admin (строка *rootpw "{SSHA}---"*) можно сделать так (заменить *adminpass* на своё значение):
`sed -i "/rootpw/ d" /etc/openldap/slapd.conf && echo "rootpw $(slappasswd -s 'adminpass')" >> /etc/openldap/slapd.conf`  
Для рутера 2 изменить значения (***ServerID 1->2, TLS... router1->router2, provider router2.home.my->router1.home.my***)

## 3.я. содержимое base.ldif:
```
dn: dc=home,dc=my
dc: home
objectClass: dcObject
objectClass: organization
o: Home Sweet Home

dn: cn=admin, dc=home,dc=my
roleOccupant: dc=home,dc=my
objectClass: organizationalRole
objectClass: top
description: LDAP administrator
cn: admin

dn: ou=Hosehold, dc=home,dc=my
ou: Hosehold
objectClass: top
objectClass: organizationalUnit

dn: ou=Group, dc=home,dc=my
ou: Group
objectClass: top
objectClass: organizationalUnit

dn: ou=Servou, dc=home,dc=my
ou: Servou
objectClass: top
objectClass: organizationalUnit

dn: cn=mirror,ou=Servou, dc=home,dc=my
userPassword: {SSHA}pCICId17J9yDreUuTazymL/eYFbyneTl
objectClass: simpleSecurityObject
objectClass: organizationalPerson
description: LDAP sync user
sn: none
cn: mirror
```

**Примечания:** пользователей загнал в *ou: Hosehold* (обычно — *Users*), учётку *cn: mirror* для синхронизации — в отдельную *ou: Servou*,  генерация  пароля — `slappasswd -s 'mirrorpass'`

## 4.а. устанавливаем и конфигурируем sssd ([PC|PC2],user):

```
sudo pacman -S sssd
sudo touch /etc/sssd/conf.d/sssd.conf (надо создавать вручную, содержимое - в  пункте 4.я)
sudo chmod 600 /etc/sssd/conf.d/sssd.conf
```

## 4.б. отключаем либо конфигурируем nscd:
```
sudo `systemctl disable nscd && systemctl stop nscd`
#либо правим /etc/nscd.conf:
enable-cache passwd no
enable-cache group no
enable-cache hosts yes
enable-cache netgroup no
```

## 4.в. редактируем /etc/nsswitch.conf:
```
passwd: files sss
group: files sss
shadow: files sss
```

## 4.г. редактируем /etc/pam.d/system-auth:
```
auth sufficient pam_sss.so forward_pass #
auth required pam_unix.so try_first_pass nullok
auth optional pam_permit.so
auth required pam_env.so

account [default=bad success=ok user_unknown=ignore authinfo_unavail=ignore] pam_sss.so #
account required pam_unix.so
account optional pam_permit.so
account required pam_time.so

password sufficient pam_sss.so use_authtok #
password required pam_unix.so try_first_pass nullok sha512 shadow
password optional pam_permit.so

session     required      pam_mkhomedir.so skel=/etc/skel/ umask=0077 #
session required pam_limits.so
session required pam_unix.so
session optional pam_sss.so #
session optional pam_permit.so
```

## 4.г. редактируем /etc/pam.d/passwd:
```
#%PAM-1.0
password        sufficient      pam_sss.so
#password       required        pam_cracklib.so difok=2 minlen=8 dcredit=2 ocredit=2 retry=3
#password       required        pam_unix.so sha512 shadow use_authtok
password        required        pam_unix.so sha512 shadow nullok
```

## 4.д. активируем и запускаем sssd:
`sudo systemctl enable sssd && sudo systemctl start sssd`

## 4.е. создаём нового юзера в LDAP и проверяем:

`ldapadd -Z -h router2.home.my -c -D "cn=admin,dc=home,dc=my" -w adminpass -f user.ldif`

```
user@PC$ cat user.ldif

dn: uid=testuser,ou=Hosehold,dc=home,dc=my
sn: ТестоваяФамилия
userPassword: {SSHA}Kz2Miwa3SCxC5GMzhIU6ZZ9v+tZ5C4AV
loginShell: /bin/bash
uidNumber: 2001
gidNumber: 2000
objectClass: posixAccount
objectClass: shadowAccount
objectClass: inetOrgPerson
uid: testuser
cn: ТестовоеИмя
preferredLanguage: ru-RU
homeDirectory: /home/testuser/

dn: cn=testgroup,ou=Group, dc=home,dc=my
gidNumber: 2000
userPassword: {crypt}x
memberUid: testuser
memberUid: user
objectClass: posixGroup
objectClass: top
cn: testgroup
```

Далее: `getent passwd testuser` либо `id testuser` и пытаемся залогиниться на любой клиентский ПК под пользователем *testuser* (пароль — *testpass*)

**Примечания:** в окне приглашения *LightDM* отображается значение поля *cn (ТестовоеИмя)*. В перечне ObjectClass первым должен идти PosixAccount.

## 4.я. содержимое sssd.conf:
```
[sssd]
config_file_version = 2
services = nss, pam
domains = LDAP

[domain/LDAP]
cache_credentials = true
enumerate = true
id_provider = ldap
auth_provider = ldap
ldap_uri = ldaps://router1.home.my
ldap_backup_uri = ldaps://router2.home.my
ldap_search_base = dc=home,dc=my
ldap_user_search_base = ou=Hosehold,dc=home,dc=my
ldap_group_search_base = ou=Group,dc=home,dc=my
ldap_id_use_start_tls = true
ldap_tls_reqcert = demand
ldap_tls_cacertdir = /etc/ssl/certs
chpass_provider = ldap
ldap_chpass_uri = ldaps://router1.home.my
ldap_chpass_backup_uri = ldaps://router2.home.my
entry_cache_timeout = 600
ldap_network_timeout = 2
ldap_schema = rfc2307
ldap_group_member = memberUid
```

**Примечания:** параметр *'enumerate = true'* нужен для отображения и выбора  доступных пользователей с uid>1000 в окне приглашения LightDM, к примеру.

## Недостатки реализации (как же без них :-)):

После пропадании питания на обоих рутерах одновременно все записи ldap пропадают. Особенности реализации OpenLDAP в OpenWRT — базы хранятся в оперативке. Решение: или держать дежурный бэкап ldif всей базы на стационарном ПК и заливать на рутер обратно при необходимости или монтировать флешку на рутере (можно одном) и в slapd.conf указывать флешку как место хранения базы. Или  использовать ИБП.
Чтобы  запретить пользователю (ребёнку) вход на ПК, приходится либо временно удалять запись в LDAP либо менять там же пароль. 

## Использованные источники (в основном): 

+ Archlinux wiki: [LDAP Authentication](https://wiki.archlinux.org/title/LDAP_authentication#SSSD_Configuration)
+ Gentoo wiki: [PKI + EasyRSA](https://wiki.gentoo.org/wiki/Create_a_Public_Key_Infrastructure_Using_the_easy-rsa_Scripts)

## Дальнейшие планы:

Накатать таки плейбук для раскатки настроек ансиблем.
