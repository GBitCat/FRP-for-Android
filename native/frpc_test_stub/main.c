#include <stdio.h>
#include <string.h>
#include <unistd.h>

/*
 * Debug-instrumentation fixture for exercising FrpcService on an x86_64
 * Android emulator. Production APKs always package the real ARM64 Go core.
 */
int main(int argc, char **argv) {
    if (argc != 3 || strcmp(argv[1], "-c") != 0) {
        return 2;
    }

    FILE *config = fopen(argv[2], "rb");
    if (config == NULL) {
        return 3;
    }
    int first_byte = fgetc(config);
    fclose(config);
    if (first_byte == EOF) {
        return 4;
    }

    puts("[I] instrumentation frpc fixture read configuration");
    fflush(stdout);
    for (;;) {
        pause();
    }
}
