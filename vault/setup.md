VAULT_VERSION="1.14.0"
curl -O https://releases.hashicorp.com/vault/${VAULT_VERSION}/vault_${VAULT_VERSION}_linux_amd64.zip
unzip vault_${VAULT_VERSION}_linux_amd64.zip

# Dev
./vault server -dev -dev-root-token-id="root" -dev-listen-address="0.0.0.0:8200"
export VAULT_ADDR='http://0.0.0.0:8200'
export VAULT_TOKEN='root'


# Prod
sudo mkdir -p /home/k8s/vault-db
sudo chown -R $(whoami) /home/k8s/vault-db
./vault server -config=vault.hcl


./vault operator init -key-shares=5 -key-threshold=3

./vault operator unseal key...



### LDAP

sudo apt-get update
sudo apt-get install -y ldap-utils

docker run --name openldap -d \
    -p 389:389 -p 636:636 \
    -e LDAP_ORGANISATION="Example Inc." \
    -e LDAP_DOMAIN="example.com" \
    -e LDAP_ADMIN_PASSWORD="AdminPassw0rd" \
    osixia/openldap

docker logs -f openldap

slappasswd -s P@ssw0rd (w kontenerze)

ldapadd -x -H ldap://127.0.0.1:389 -D "cn=admin,dc=example,dc=com" -w "AdminPassw0rd" -f ldap.ldif

ldapsearch -x -H ldap://127.0.0.1:389 -D "cn=admin,dc=example,dc=com" -w "AdminPassw0rd" -b "dc=example,dc=com" "(objectClass=*)"

ldapsearch -x -H ldap://127.0.0.1:389 -D "cn=admin,dc=example,dc=com" -w "AdminPassw0rd" -b "ou=Groups,dc=example,dc=com" "(cn=vault-password-users)"

### VAULT config

./vault auth enable ldap

./vault write auth/ldap/config url="ldap://127.0.0.1:389" \
    userdn="ou=Users,dc=example,dc=com" \
    groupdn="ou=Groups,dc=example,dc=com" \
    binddn="cn=admin,dc=example,dc=com" \
    bindpass="AdminPassw0rd" \
    userattr="uid" \
    insecure_tls=true

./vault write auth/ldap/config \
    url="ldap://127.0.0.1:389" \
    binddn="cn=admin,dc=example,dc=com" \
    bindpass="AdminPassw0rd" \
    userdn="ou=Users,dc=example,dc=com" \
    userattr="uid" \
    userfilter="(&(objectClass=inetOrgPerson)(uid={{.Username}})(member=cn=vault,ou=Groups,dc=example,dc=com))" \
    groupdn="ou=Groups,dc=example,dc=com" \
    groupattr="cn" \
    groupfilter="(&(objectClass=groupOfNames)(cn=vault)(member={{.UserDN}}))" \
    insecure_tls=true

./vault policy write kv-password kv-password.hcl
./vault secrets list (opcja, sprawdzenie włączonych mechanizmów)
./vault secrets enable -path=secret -version=2 kv

./vault write auth/ldap/groups/vault-password-users policies="kv-password"

### Test

Login
./vault login -method=ldap username=jdoe

Add secret
./vault kv put secret/passwords/db-server username="dbuser" password="S3cr3tDBPass!" 

Read password 
./vault kv get secret/passwords/db-server

List all
./vault kv list secret/passwords

Update 
./vault kv put secret/passwords/db-server username="dbuser" password="NewP@ssw0rd!"

Delete
./vault kv delete secret/passwords/db-server