#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/xattr.h>

static void fail(const char* operation, const char* path, const char* name)
{
    fprintf(stderr, "%s xattr %s on %s failed: %s\n",
            operation, name, path, strerror(errno));
    exit(EXIT_FAILURE);
}

int main(int argc, char** argv)
{
    if (argc == 5 && strcmp(argv[1], "set") == 0) {
        const char* value = argv[4];
        if (setxattr(argv[2], argv[3], value, strlen(value), 0) != 0) {
            fail("set", argv[2], argv[3]);
        }
        return EXIT_SUCCESS;
    }

    if (argc == 4 && strcmp(argv[1], "get") == 0) {
        ssize_t size = getxattr(argv[2], argv[3], NULL, 0);
        if (size < 0) {
            fail("get", argv[2], argv[3]);
        }

        size_t allocation = size > 0 ? (size_t) size : 1U;
        char* value = malloc(allocation);
        if (value == NULL) {
            perror("malloc");
            return EXIT_FAILURE;
        }

        ssize_t received = getxattr(argv[2], argv[3], value, allocation);
        if (received < 0) {
            free(value);
            fail("get", argv[2], argv[3]);
        }
        if (received > 0 && fwrite(value, 1, (size_t) received, stdout) != (size_t) received) {
            free(value);
            perror("fwrite");
            return EXIT_FAILURE;
        }
        free(value);
        return EXIT_SUCCESS;
    }

    fprintf(stderr, "usage: %s set PATH NAME VALUE | get PATH NAME\n", argv[0]);
    return EXIT_FAILURE;
}
