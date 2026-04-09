#include <stdio.h>
#include <string.h>
#include <openssl/sha.h>

int main() {
    // The string we want to hash
    const char *message = "Hello, OpenSSL!";
    
    // Buffer to hold the hash (SHA256_DIGEST_LENGTH = 32 bytes)
    unsigned char hash[SHA256_DIGEST_LENGTH];

    // Compute SHA-256 hash
    SHA256((unsigned char*)message, strlen(message), hash);

    // Print the hash in hex
    printf("SHA-256 hash of \"%s\":\n", message);
    for (int i = 0; i < SHA256_DIGEST_LENGTH; i++) {
        printf("%02x", hash[i]);
    }
    printf("\n");

    return 0;
}