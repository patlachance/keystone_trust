#!/bin/sh

# Keystone oAuth API example
# https://review.openstack.org/#/c/29130/37
# In this use case we illustrate access delegation to swift via oAuth.

# This script is expected to be run on a devstack-like install.
# keystone and swift must be running.

# add this to devstack/localrc to activate oAuth with keystone:
#KEYSTONE_TOKEN_FORMAT=PKI
#KEYSTONE_REPO=https://mhu@review.openstack.org/openstack/keystone
#KEYSTONE_BRANCH=refs/changes/30/29130/35

# change these to your own settings

TENANT_NAME=admin
USERNAME=admin
PASSWORD=admin

# the script is run locally
URL=127.0.0.1

export OS_TENANT_NAME=$TENANT_NAME
export OS_USERNAME=$USERNAME
export OS_PASSWORD=$PASSWORD
export OS_AUTH_URL=http://$URL:5000/v2.0

# Setting up the test environment

echo "** Create test tenant"

keystone tenant-create --name TestTenant1
# Get the tenants IDs
TENANT1=$(keystone tenant-get TestTenant1 |awk '{if ($2 == "id") {print $4}}')
MEMBER_ID=$(keystone role-get Member |awk '{if ($2 == "id") {print $4}}')
keystone role-create --name MyFancyRole
ROLE_ID=$(keystone role-get MyFancyRole |awk '{if ($2 == "id") {print $4}}')

echo "** Create test user"
keystone user-create --name User1 --tenant-id $TENANT1 --pass User1 --enabled true
# Get the users IDs
USER1=$(keystone user-get User1 |awk '{if ($2 == "id") {print $4}}')

echo "** Allow User1 to do stuff on swift"
keystone user-role-add --user-id $USER1 --role-id $MEMBER_ID --tenant-id $TENANT1
# Add the extra role to single out accesses from the delegate and the real deal
keystone user-role-add --user-id $USER1 --role-id $ROLE_ID --tenant-id $TENANT1

echo "** Upload stuff as User1"
echo "this is file1" > file1
echo "this is file2" > file2
echo "this is file3" > file3
swift --os-username User1 --os-password User1 --os-tenant-name TestTenant1 upload stuff file1 file2

echo "** Get V3 tokens" 
# cannot use V2 tokens with trusts, even though it should be possible
# see: https://bugs.launchpad.net/keystone/+bug/1182448
#TOKEN1=$(curl -i -d '{ "auth": { "identity": { "methods": [ "password" ], "password": { "user": { "id": "'$USER1'", "password": "User1" } } } } }' -H "Content-type: application/json" http://$URL:5000/v3/auth/tokens| awk '{if ($1 =="X-Subject-Token:") {print $2}}' | col -b)
TOKEN1=$(keystone --os-username User1 --os-tenant-name TestTenant1 --os-password User1 token-get |awk '{if ($2 == "id") {print $4}}')
echo $TOKEN1

#ADMIN_TOKEN=$(curl -i -d '{ "auth": { "identity": { "methods": [ "password" ], "password": { "user": { "id": "'$USERNAME'", "password": "'$PASSWORD'" } } } } }' -H "Content-type: application/json" http://$URL:5000/v3/auth/tokens| awk '{if ($1 =="X-Subject-Token:") {print $2}}' | col -b)
ADMIN_TOKEN=$(keystone token-get |awk '{if ($2 == "id") {print $4}}')
echo $ADMIN_TOKEN

echo "** Register as a Consumer"
CONSUMER=$(curl -H "X-Auth-Token: $ADMIN_TOKEN" -d '{ "consumer": { "name": "MyConsumer" } }' -H "Content-Type: application/json" http://$URL:5000/v3/OS-OAUTH10A/consumers)

echo $CONSUMER

CONSUMER_ID=$(echo $CONSUMER| python -c 'import json,sys; obj=json.load(sys.stdin); print obj["consumer"]["id"]' | col -b)
CONSUMER_KEY=$(echo $CONSUMER| python -c 'import json,sys; obj=json.load(sys.stdin); print obj["consumer"]["consumer_key"]' | col -b)
CONSUMER_SECRET=$(echo $CONSUMER| python -c 'import json,sys; obj=json.load(sys.stdin); print obj["consumer"]["consumer_secret"]' | col -b)

echo "** Make an access request for our Consumer"
# python to the rescue
REQUEST_TOKEN=$(python -c 'import oauth2; consumer=oauth2.Consumer("'$CONSUMER_KEY'", "'$CONSUMER_SECRET'"); client=oauth2.Client(consumer); resp, content=client.request("http://'$URL':5000/v3/OS-OAUTH10A/request_token?requested_roles='$MEMBER_ID'"); print content')
REQUEST_TOKEN_KEY=$(echo $REQUEST_TOKEN| python -c 'import json,sys; obj=json.load(sys.stdin); print obj["token"]["request_token_key"]' | col -b)
REQUEST_TOKEN_SECRET=$(echo $REQUEST_TOKEN| python -c 'import json,sys; obj=json.load(sys.stdin); print obj["token"]["request_token_secret"]' | col -b)

# one has to be admin to authorize a request ?
VERIFIER=$(curl -X POST -H "X-Auth-Token: $TOKEN1" http://$URL:5000/v3/OS-OAUTH10A/authorize/$REQUEST_TOKEN_KEY/$MEMBER_ID)
echo $VERIFIER
OAUTH_VERIFIER=$(echo $VERIFIER| python -c 'import json,sys; obj=json.load(sys.stdin); print obj["token"]["oauth_verifier"]' )

echo "** Validate request with User1"
ACCESS_TOKEN=$(python -c 'import oauth2; consumer=oauth2.Consumer("'$CONSUMER_KEY'", "'$CONSUMER_SECRET'"); token = oauth2.Token("'$REQUEST_TOKEN_KEY'", "'$REQUEST_TOKEN_SECRET'"); token.set_verifier("'$OAUTH_VERIFIER'");  client=oauth2.Client(consumer, token); resp, content=client.request("http://'$URL':5000/v3/OS-OAUTH10A/access_token"); print content')
ACCESS_TOKEN_KEY=$(echo $ACCESS_TOKEN| python -c 'import json,sys; obj=json.load(sys.stdin); print obj["token"]["access_token_key"]' | col -b)
ACCESS_TOKEN_SECRET=$(echo $ACCESS_TOKEN| python -c 'import json,sys; obj=json.load(sys.stdin); print obj["token"]["access_token_secret"]' | col -b)

echo "** Fetch access token"
AUTH_TOKEN=$(python -c 'import oauth2; consumer=oauth2.Consumer("'$CONSUMER_KEY'", "'$CONSUMER_SECRET'"); token = oauth2.Token("'$ACCESS_TOKEN_KEY'", "'$ACCESS_TOKEN_SECRET'");   client=oauth2.Client(consumer, token); resp, content=client.request("http://'$URL':5000/v3/OS-OAUTH10A/authenticate"); print content')
echo $AUTH_TOKEN | python -mjson.tool
TRUST_TOKEN=$(echo $AUTH_TOKEN| python -c 'import json,sys; obj=json.load(sys.stdin); print obj["token"]["id"]' | col -b)

#echo "** Create trust: Trustor User1, Trustee User2, role delegation: Member"
#TRUST=$(curl -H "X-Auth-Token: $TOKEN1" -d '{ "trust": { "expires_at": "2024-02-27T18:30:59.999999Z", "impersonation": false, "project_id": "'$TENANT1'", "roles": [ { "name": "Member" } ], "trustee_user_id": "'$USER2'", "trustor_user_id": "'$USER1'" }}' -H "Content-type: application/json" http://$URL:35357/v3/OS-TRUST/trusts)
#echo $TRUST| python -mjson.tool
#TRUST_ID=$(echo $TRUST| python -c 'import json,sys; obj=json.load(sys.stdin); print obj["trust"]["id"]' | col -b)
##echo $TRUST_ID

#echo "** Get Trust token"
#TRUST_JSON='{ "auth" : { "identity" : { "methods" : [ "token" ], "token" : { "id" : "'$TOKEN2'" } }, "scope" : { "OS-TRUST:trust" : { "id" : "'$TRUST_ID'" } } } }'
##echo $TRUST_JSON | python -mjson.tool
##TRUST_CONSUME=$(curl -i -d "$TRUST_JSON" -H "Content-type: application/json" http://$URL:35357/v3/auth/tokens)
##echo $TRUST_CONSUME
#TRUST_TOKEN=$(curl -i -d "$TRUST_JSON" -H "Content-type: application/json" http://$URL:35357/v3/auth/tokens| awk '{if ($1 =="X-Subject-Token:") {print $2}}')
echo $TRUST_TOKEN

#here the token fails to be linked to a tenant:
#proxy-server Using identity: {'roles': [u'MyFancyRole', u'_member_', u'Member'], 'user': u'User1', 'tenant': (None, None)} (txn: tx8caf73eeafe34aa59bb34-0051ecf844)
#proxy-server tenant mismatch: AUTH_4f3ab3d2319c49748361ec2b9be9f4cb != None (txn: tx8caf73eeafe34aa59bb34-0051ecf844) (client_ip: 127.0.0.1)
#proxy-server tenant mismatch: AUTH_4f3ab3d2319c49748361ec2b9be9f4cb != None (txn: tx8caf73eeafe34aa59bb34-0051ecf844) (client_ip: 127.0.0.1)

echo "** List items owned by User1 using the Trust token (cURL)"
curl -H 'X-Auth-Token: '$TRUST_TOKEN'' http://$URL:8080/v1/AUTH_$TENANT1/stuff

# Excerpt from the swift server proxy logs:
#
#proxy-server Storing $TRUST_TOKEN token in memcache
#proxy-server STDOUT: WARNING:root:parameter timeout has been deprecated, use time (txn: txedd37c6afd9246459d1cf-0051e41204)
#proxy-server Using identity: {'roles': [u'Member'], 'user': u'User2', 'tenant': (u'58aa10296ed94ea696a83817e43f6d40', u'TestTenant1')} (txn: txedd37c6afd9246459d1cf-0051e41204)
#
# If impersonation was set to true, the user would appear as User1, with restricted roles

echo "** Do it again with the swift CLI"
unset OS_TENANT_NAME
unset OS_USERNAME
unset OS_PASSWORD
swift --os-auth-token $TRUST_TOKEN --os-storage-url http://$URL:8080/v1/AUTH_$TENANT1 -V 2 list stuff

echo "** Upload a file on behalf of User1"
curl -X PUT -T file3 -H 'X-Auth-Token: '$TRUST_TOKEN'' http://$URL:8080/v1/AUTH_$TENANT1/stuff/file3
swift --os-username User1 --os-password User1 --os-tenant-name TestTenant1 list stuff

echo "** Cleanup"
rm file1 file2 file3
swift --os-username User1 --os-password User1 --os-tenant-name TestTenant1 delete stuff
export OS_TENANT_NAME=$TENANT_NAME
export OS_USERNAME=$USERNAME
export OS_PASSWORD=$PASSWORD
keystone user-delete User1
keystone role-delete MyFancyRole
keystone tenant-delete TestTenant1