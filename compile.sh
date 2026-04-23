wget https://github.com/openssl/openssl/releases/download/openssl-4.0.0/openssl-4.0.0.tar.gz
tar -xf openssl-4.0.0.tar.gz
cd openssl-4.0.0
./Configure -static
make
cd ..
cp openssl-4.0.0/apps/openssl .

./01-unpack-debs.sh debs openssl

# Generación de valor dummie para iterar sobre el único ejecutable
echo "test/test/unknown/x86-64" >> libs/all_libs

./02-generate-fidb.sh ~/ghidra_home