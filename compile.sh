gcc openssl_test.c libcrypto.a -o openssl_test -fvisibility=hidden
strip --strip-all openssl_test