#!/usr/bin/env bash

# shellcheck disable=SC2120
exit_1() {
	cleanup

	echo "minio1 ============"
	cat /tmp/minio1_1.log
	echo "minio2 ============"
	cat /tmp/minio2_1.log

	exit 1
}

cleanup() {
	echo -n "Cleaning up instances of MinIO ..."
	pkill -9 minio || sudo pkill -9 minio
	pkill -9 kes || sudo pkill -9 kes
	rm -rf ${PWD}/keys
	rm -rf /tmp/minio{1,2}
	echo "done"
}

cleanup

export MINIO_CI_CD=1
export MINIO_BROWSER=off
export MINIO_ROOT_USER="minio"
export MINIO_ROOT_PASSWORD="minio123"

# Create certificates for TLS enabled MinIO
echo -n "Setup certs for MinIO instances ..."
wget -O certgen https://github.com/minio/certgen/releases/latest/download/certgen-linux-amd64 && chmod +x certgen
./certgen --host localhost
mkdir -p ~/.minio/certs
mv public.crt ~/.minio/certs || sudo mv public.crt ~/.minio/certs
mv private.key ~/.minio/certs || sudo mv private.key ~/.minio/certs
echo "done"

# Deploy KES and start
echo "Setup KES for MinIO instances ..."
wget -O kes https://github.com/minio/kes/releases/download/2024-03-13T17-52-13Z/kes-linux-amd64 && chmod +x kes
./kes identity new --key private.key --cert public.crt --ip "127.0.0.1" localhost --force
./kes identity new --key=minio.key --cert=minio.crt MinIO --force
MINIO_KES_IDENTITY=$(kes identity of minio.crt | awk NF)
cat >kes-config.yml <<EOF
address: 0.0.0.0:7373

admin:
  identity: disabled

tls:
  key: private.key
  cert: public.crt

policy:
  my-app:
    allow:
    - /v1/key/list/*
    - /v1/key/generate/*
    - /v1/key/decrypt/*
    - /v1/key/create/*
    - /v1/secret/list/*
    - /v1/status
    identities:
    - ${MINIO_KES_IDENTITY}

keystore:
  fs:
    path: ./keys
EOF
./kes server --config kes-config.yml --auth off >/tmp/kes.log 2>&1 &
echo "done"

# Start MinIO instances
echo -n "Starting MinIO instances ..."
CI=on MINIO_KMS_KES_ENDPOINT=https://127.0.0.1:7373 MINIO_KMS_KES_CERT_FILE=${PWD}/minio.crt MINIO_KMS_KES_KEY_FILE=${PWD}/minio.key MINIO_KMS_KES_KEY_NAME=minio-default-key MINIO_KMS_KES_CAPATH=${PWD}/public.crt MINIO_ROOT_USER=minio MINIO_ROOT_PASSWORD=minio123 minio server --address ":9001" --console-address ":10000" /tmp/minio1/{1...4}/disk{1...4} /tmp/minio1/{5...8}/disk{1...4} >/tmp/minio1_1.log 2>&1 &
CI=on MINIO_KMS_KES_ENDPOINT=https://127.0.0.1:7373 MINIO_KMS_KES_CERT_FILE=${PWD}/minio.crt MINIO_KMS_KES_KEY_FILE=${PWD}/minio.key MINIO_KMS_KES_KEY_NAME=minio-default-key MINIO_KMS_KES_CAPATH=${PWD}/public.crt MINIO_ROOT_USER=minio MINIO_ROOT_PASSWORD=minio123 minio server --address ":9002" --console-address ":11000" /tmp/minio2/{1...4}/disk{1...4} /tmp/minio2/{5...8}/disk{1...4} >/tmp/minio2_1.log 2>&1 &
echo "done"

if [ ! -f ./mc ]; then
	echo -n "Downloading MinIO client ..."
	wget -O mc https://dl.min.io/client/mc/release/linux-amd64/mc &&
		chmod +x mc
	echo "done"
fi

sleep 10

export MC_HOST_minio1=https://minio:minio123@localhost:9001
export MC_HOST_minio2=https://minio:minio123@localhost:9002

# Prepare data for tests
echo -n "Preparing test data ..."
mkdir -p /tmp/data
echo "Hello from encrypted world" >/tmp/data/encrypted
touch /tmp/data/defpartsize
shred -s 500M /tmp/data/defpartsize
touch /tmp/data/custpartsize
shred -s 500M /tmp/data/custpartsize
echo "done"

# Add replication site
./mc admin replicate add minio1 minio2 --insecure
# sleep for replication to complete
sleep 30

# Create bucket in source cluster
echo "Create bucket in source MinIO instance"
./mc mb minio1/test-bucket --insecure

# Enable SSE KMS for the bucket
./mc encrypt set sse-kms minio-default-key minio1/test-bucket --insecure

# Load objects to source site
echo "Loading objects to source MinIO instance"
./mc cp /tmp/data/encrypted minio1/test-bucket --insecure
./mc cp /tmp/data/defpartsize minio1/test-bucket --insecure
./mc put /tmp/data/custpartsize minio1/test-bucket --insecure --part-size 50MiB
sleep 120

# List the objects from source site
echo "Objects from source instance"
./mc ls minio1/test-bucket --insecure
count1=$(./mc ls minio1/test-bucket/encrypted --insecure | wc -l)
if [ "${count1}" -ne 1 ]; then
	echo "BUG: object minio1/test-bucket/encrypted not found"
	exit_1
fi
count2=$(./mc ls minio1/test-bucket/defpartsize --insecure | wc -l)
if [ "${count2}" -ne 1 ]; then
	echo "BUG: object minio1/test-bucket/defpartsize not found"
	exit_1
fi
count3=$(./mc ls minio1/test-bucket/custpartsize --insecure | wc -l)
if [ "${count3}" -ne 1 ]; then
	echo "BUG: object minio1/test-bucket/custpartsize not found"
	exit_1
fi

# List the objects from replicated site
echo "Objects from replicated instance"
./mc ls minio2/test-bucket --insecure
repcount1=$(./mc ls minio2/test-bucket/encrypted --insecure | wc -l)
if [ "${repcount1}" -ne 1 ]; then
	echo "BUG: object test-bucket/encrypted not replicated"
	exit_1
fi
repcount2=$(./mc ls minio2/test-bucket/defpartsize --insecure | wc -l)
if [ "${repcount2}" -ne 1 ]; then
	echo "BUG: object test-bucket/defpartsize not replicated"
	exit_1
fi

repcount3=$(./mc ls minio2/test-bucket/custpartsize --insecure | wc -l)
if [ "${repcount3}" -ne 1 ]; then
	echo "BUG: object test-bucket/custpartsize not replicated"
	exit_1
fi

# Stat the objects from source site
echo "Stat minio1/test-bucket/encrypted"
./mc stat minio1/test-bucket/encrypted --insecure --json
stat_out1=$(./mc stat minio1/test-bucket/encrypted --insecure --json)
src_obj1_algo=$(echo "${stat_out1}" | jq '.metadata."X-Amz-Server-Side-Encryption"')
src_obj1_keyid=$(echo "${stat_out1}" | jq '.metadata."X-Amz-Server-Side-Encryption-Aws-Kms-Key-Id"')
echo "Stat minio1/test-bucket/defpartsize"
./mc stat minio1/test-bucket/defpartsize --insecure --json
stat_out2=$(./mc stat minio1/test-bucket/defpartsize --insecure --json)
src_obj2_algo=$(echo "${stat_out2}" | jq '.metadata."X-Amz-Server-Side-Encryption"')
src_obj2_keyid=$(echo "${stat_out2}" | jq '.metadata."X-Amz-Server-Side-Encryption-Aws-Kms-Key-Id"')
echo "Stat minio1/test-bucket/custpartsize"
./mc stat minio1/test-bucket/custpartsize --insecure --json
stat_out3=$(./mc stat minio1/test-bucket/custpartsize --insecure --json)
src_obj3_algo=$(echo "${stat_out3}" | jq '.metadata."X-Amz-Server-Side-Encryption"')
src_obj3_keyid=$(echo "${stat_out3}" | jq '.metadata."X-Amz-Server-Side-Encryption-Aws-Kms-Key-Id"')

# Stat the objects from replicated site
echo "Stat minio2/test-bucket/encrypted"
./mc stat minio2/test-bucket/encrypted --insecure --json
stat_out1_rep=$(./mc stat minio2/test-bucket/encrypted --insecure --json)
rep_obj1_algo=$(echo "${stat_out1_rep}" | jq '.metadata."X-Amz-Server-Side-Encryption"')
rep_obj1_keyid=$(echo "${stat_out1_rep}" | jq '.metadata."X-Amz-Server-Side-Encryption-Aws-Kms-Key-Id"')
echo "Stat minio2/test-bucket/defpartsize"
./mc stat minio2/test-bucket/defpartsize --insecure --json
stat_out2_rep=$(./mc stat minio2/test-bucket/defpartsize --insecure --json)
rep_obj2_algo=$(echo "${stat_out2_rep}" | jq '.metadata."X-Amz-Server-Side-Encryption"')
rep_obj2_keyid=$(echo "${stat_out2_rep}" | jq '.metadata."X-Amz-Server-Side-Encryption-Aws-Kms-Key-Id"')
echo "Stat minio2/test-bucket/custpartsize"
./mc stat minio2/test-bucket/custpartsize --insecure --json
stat_out3_rep=$(./mc stat minio2/test-bucket/custpartsize --insecure --json)
rep_obj3_algo=$(echo "${stat_out3_rep}" | jq '.metadata."X-Amz-Server-Side-Encryption"')
rep_obj3_keyid=$(echo "${stat_out3_rep}" | jq '.metadata."X-Amz-Server-Side-Encryption-Aws-Kms-Key-Id"')

# Check the algo and keyId of replicated objects
if [ "${rep_obj1_algo}" != "${src_obj1_algo}" ]; then
	echo "BUG: Algorithm: '${rep_obj1_algo}' of replicated object: 'minio2/test-bucket/encrypted' doesn't match with source value: '${src_obj1_algo}'"
	exit_1
fi
if [ "${rep_obj1_keyid}" != "${src_obj1_keyid}" ]; then
	echo "BUG: KeyId: '${rep_obj1_keyid}' of replicated object: 'minio2/test-bucket/encrypted' doesn't match with source value: '${src_obj1_keyid}'"
	exit_1
fi
if [ "${rep_obj2_algo}" != "${src_obj2_algo}" ]; then
	echo "BUG: Algorithm: '${rep_obj2_algo}' of replicated object: 'minio2/test-bucket/defpartsize' doesn't match with source value: '${src_obj2_algo}'"
	exit_1
fi
if [ "${rep_obj2_keyid}" != "${src_obj2_keyid}" ]; then
	echo "BUG: KeyId: '${rep_obj2_keyid}' of replicated object: 'minio2/test-bucket/defpartsize' doesn't match with source value: '${src_obj2_keyid}'"
	exit_1
fi
if [ "${rep_obj3_algo}" != "${src_obj3_algo}" ]; then
	echo "BUG: Algorithm: '${rep_obj3_algo}' of replicated object: 'minio2/test-bucket/custpartsize' doesn't match with source value: '${src_obj3_algo}'"
	exit_1
fi
if [ "${rep_obj3_keyid}" != "${src_obj3_keyid}" ]; then
	echo "BUG: KeyId: '${rep_obj3_keyid}' of replicated object: 'minio2/test-bucket/custpartsize' doesn't match with source value: '${src_obj3_keyid}'"
	exit_1
fi

# Check content of replicated objects
./mc cat minio2/test-bucket/encrypted --insecure
./mc cat minio2/test-bucket/defpartsize --insecure >/dev/null || exit_1
./mc cat minio2/test-bucket/custpartsize --insecure >/dev/null || exit_1

cleanup
