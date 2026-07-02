#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

typedef char SMCBytes_t[32];

typedef struct {
    unsigned char major;
    unsigned char minor;
    unsigned char build;
    unsigned char reserved;
    unsigned short release;
} SMCVersionData_t;

typedef struct {
    unsigned short version;
    unsigned short length;
    unsigned int cpuPLimit;
    unsigned int gpuPLimit;
    unsigned int memPLimit;
} SMCPLimitData_t;

typedef struct {
    unsigned int dataSize;
    unsigned int dataType;
    unsigned char dataAttributes;
} SMCKeyInfoData_t;

typedef struct {
    unsigned int key;
    SMCVersionData_t vers;
    SMCPLimitData_t pLimitData;
    SMCKeyInfoData_t keyInfo;
    unsigned char result;
    unsigned char status;
    unsigned char data8;
    unsigned int data32;
    SMCBytes_t bytes;
} SMCKeyData_t;

enum {
    kSMCUserClientOpen = 0,
    kSMCUserClientClose = 1,
    kSMCHandleYPCEvent = 2,
};

static const unsigned char kSMCReadBytes = 5;
static const unsigned char kSMCWriteBytes = 6;
static const unsigned char kSMCGetKeyInfo = 9;

static io_connect_t conn = 0;

static unsigned int fourcc(const char *s) {
    return ((unsigned int)s[0] << 24) | ((unsigned int)s[1] << 16) |
           ((unsigned int)s[2] << 8) | (unsigned int)s[3];
}

static int smc_open(void) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return 0;
    kern_return_t kr = IOServiceOpen(service, mach_task_self(), 0, &conn);
    IOObjectRelease(service);
    return kr == KERN_SUCCESS && conn != 0;
}

static void smc_close(void) {
    if (conn) IOServiceClose(conn);
    conn = 0;
}

static kern_return_t smc_call(SMCKeyData_t *input, SMCKeyData_t *output) {
    size_t inputSize = sizeof(SMCKeyData_t);
    size_t outputSize = sizeof(SMCKeyData_t);
    return IOConnectCallStructMethod(conn, kSMCHandleYPCEvent, input, inputSize, output, &outputSize);
}

static int key_info(unsigned int key, unsigned int *size, unsigned int *type) {
    SMCKeyData_t input = {0};
    SMCKeyData_t output = {0};
    input.key = key;
    input.data8 = kSMCGetKeyInfo;
    if (smc_call(&input, &output) != KERN_SUCCESS || output.result != 0) return 0;
    *size = output.keyInfo.dataSize;
    *type = output.keyInfo.dataType;
    return *size > 0 && *size <= 32;
}

static double decode(unsigned int type, const unsigned char *b, unsigned int size) {
    if (type == fourcc("flt ") && size >= 4) {
        unsigned int bits = ((unsigned int)b[0]) | ((unsigned int)b[1] << 8) |
                            ((unsigned int)b[2] << 16) | ((unsigned int)b[3] << 24);
        float f;
        memcpy(&f, &bits, sizeof(float));
        return f;
    }
    if (type == fourcc("fpe2") && size >= 2) return (double)(((int)b[0] << 6) + ((int)b[1] >> 2));
    if (type == fourcc("ui8 ")) return b[0];
    if (type == fourcc("ui16") && size >= 2) return (double)(((unsigned int)b[0] << 8) | (unsigned int)b[1]);
    if (type == fourcc("ui32") && size >= 4) {
        return (double)(((unsigned int)b[0] << 24) | ((unsigned int)b[1] << 16) |
                        ((unsigned int)b[2] << 8) | (unsigned int)b[3]);
    }
    unsigned long long v = 0;
    for (unsigned int i = 0; i < size && i < 8; i++) v = (v << 8) | b[i];
    return (double)v;
}

static int read_value(unsigned int key, double *value) {
    unsigned int size = 0, type = 0;
    if (!key_info(key, &size, &type)) return 0;

    SMCKeyData_t input = {0};
    SMCKeyData_t output = {0};
    input.key = key;
    input.keyInfo.dataSize = size;
    input.data8 = kSMCReadBytes;
    if (smc_call(&input, &output) != KERN_SUCCESS || output.result != 0) return 0;
    *value = decode(type, (const unsigned char *)output.bytes, size);
    return 1;
}

static int read_u16_key(const char *keyName, unsigned short *value) {
    double v = 0;
    if (!read_value(fourcc(keyName), &v)) return 0;
    if (v < 0) v = 0;
    if (v > 65535) v = 65535;
    *value = (unsigned short)(v + 0.5);
    return 1;
}

static int write_u16(unsigned int key, unsigned short value) {
    unsigned int size = 0, type = 0;
    if (!key_info(key, &size, &type)) return 0;

    unsigned char bytes[32] = {0};
    if (type == fourcc("flt ")) {
        float f = (float)value;
        unsigned int bits = 0;
        memcpy(&bits, &f, sizeof(float));
        bytes[0] = bits & 0xff;
        bytes[1] = (bits >> 8) & 0xff;
        bytes[2] = (bits >> 16) & 0xff;
        bytes[3] = (bits >> 24) & 0xff;
    } else if (type == fourcc("fpe2")) {
        unsigned int raw = (unsigned int)value * 4;
        if (raw > 65535) raw = 65535;
        bytes[0] = (raw >> 8) & 0xff;
        bytes[1] = raw & 0xff;
    } else if (size == 4) {
        bytes[0] = (value >> 24) & 0xff;
        bytes[1] = (value >> 16) & 0xff;
        bytes[2] = (value >> 8) & 0xff;
        bytes[3] = value & 0xff;
    } else if (size == 2) {
        bytes[0] = (value >> 8) & 0xff;
        bytes[1] = value & 0xff;
    } else {
        bytes[0] = value > 255 ? 255 : value;
    }

    SMCKeyData_t input = {0};
    SMCKeyData_t output = {0};
    input.key = key;
    input.data8 = kSMCWriteBytes;
    input.keyInfo.dataSize = size;
    memcpy(input.bytes, bytes, size);
    if (smc_call(&input, &output) != KERN_SUCCESS || output.result != 0) return 0;
    return 1;
}

static void fan_key(char *out, int fan, const char *suffix) {
    snprintf(out, 5, "F%d%s", fan, suffix);
}

static int fan_count(void) {
    unsigned short count = 0;
    if (!read_u16_key("FNum", &count)) return 0;
    if (count > 9) return 0;
    return (int)count;
}

static unsigned short fan_limit(int fan, const char *suffix, unsigned short fallback) {
    char key[5] = {0};
    unsigned short value = fallback;
    fan_key(key, fan, suffix);
    read_u16_key(key, &value);
    return value;
}

static void wait_for_mode(int fan, unsigned short target) {
    char md[5] = {0};
    char lower[5] = {0};
    fan_key(md, fan, "Md");
    fan_key(lower, fan, "md");

    for (int i = 0; i < 30; i++) {
        unsigned short v = 999;
        if (read_u16_key(md, &v) || read_u16_key(lower, &v)) {
            if (v == target) return;
        }
        usleep(200000);
    }
}

static int set_percent(double pct) {
    int count = fan_count();
    if (count <= 0) return 2;

    unsigned int fs = fourcc("FS! ");
    unsigned int ftst = fourcc("Ftst");
    unsigned int infoSize = 0, infoType = 0;
    int hasFS = key_info(fs, &infoSize, &infoType);
    int hasFtst = key_info(ftst, &infoSize, &infoType);
    int useFS = hasFS && !hasFtst;

    if (useFS) {
        unsigned short mask = 0;
        for (int i = 0; i < count; i++) mask |= (unsigned short)(1 << i);
        if (!write_u16(fs, mask)) return 3;
    } else {
        if (hasFtst && !write_u16(ftst, 1)) return 5;
    }

    int failures = 0;
    for (int i = 0; i < count; i++) {
        unsigned short min = fan_limit(i, "Mn", 0);
        unsigned short max = fan_limit(i, "Mx", 0);
        if (max == 0) {
            failures++;
            continue;
        }

        char tg[5] = {0}, md[5] = {0}, lower[5] = {0};
        fan_key(tg, i, "Tg");
        fan_key(md, i, "Md");
        fan_key(lower, i, "md");

        if (!useFS) {
            write_u16(fourcc(md), 1);
            write_u16(fourcc(lower), 1);
        }

        int rpm = (int)((double)max * pct / 100.0 + 0.5);
        if (rpm < min) rpm = min;
        if (rpm > max) rpm = max;
        if (!write_u16(fourcc(tg), (unsigned short)rpm)) failures++;
    }

    return failures == 0 ? 0 : 4;
}

static int reset_auto(void) {
    int count = fan_count();
    if (count <= 0) return 2;

    unsigned int fs = fourcc("FS! ");
    unsigned int ftst = fourcc("Ftst");
    unsigned int infoSize = 0, infoType = 0;
    int hasFS = key_info(fs, &infoSize, &infoType);
    int hasFtst = key_info(ftst, &infoSize, &infoType);
    int useFS = hasFS && !hasFtst;

    if (useFS) {
        return write_u16(fs, 0) ? 0 : 3;
    }

    for (int i = 0; i < count; i++) {
        char md[5] = {0}, lower[5] = {0};
        fan_key(md, i, "Md");
        fan_key(lower, i, "md");
        write_u16(fourcc(md), 0);
        write_u16(fourcc(lower), 0);
    }
    if (hasFtst) write_u16(ftst, 0);
    return 0;
}

static int run_command(const char *command, const char *arg) {
    if (strcmp(command, "full") == 0) {
        return set_percent(100.0);
    }
    if (strcmp(command, "set") == 0 && arg != NULL) {
        double pct = atof(arg);
        if (pct < 0) pct = 0;
        if (pct > 100) pct = 100;
        return set_percent(pct);
    }
    if (strcmp(command, "auto") == 0) {
        return reset_auto();
    }
    return 64;
}

static int serve(const char *socket_path, const char *token, uid_t owner_uid) {
    if (strlen(socket_path) >= sizeof(((struct sockaddr_un *)0)->sun_path)) return 65;

    int server = socket(AF_UNIX, SOCK_STREAM, 0);
    if (server < 0) return 70;

    unlink(socket_path);

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, socket_path, sizeof(addr.sun_path) - 1);

    if (bind(server, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(server);
        return 71;
    }
    chown(socket_path, owner_uid, (gid_t)-1);
    chmod(socket_path, 0600);

    if (listen(server, 4) != 0) {
        close(server);
        unlink(socket_path);
        return 72;
    }

    time_t last_activity = time(NULL);
    for (;;) {
        fd_set readfds;
        FD_ZERO(&readfds);
        FD_SET(server, &readfds);

        struct timeval timeout;
        timeout.tv_sec = 300;
        timeout.tv_usec = 0;

        int ready = select(server + 1, &readfds, NULL, NULL, &timeout);
        if (ready <= 0) {
            if (time(NULL) - last_activity >= 300) break;
            continue;
        }

        int client = accept(server, NULL, NULL);
        if (client < 0) continue;
        last_activity = time(NULL);

        char buffer[256] = {0};
        ssize_t n = read(client, buffer, sizeof(buffer) - 1);
        if (n <= 0) {
            close(client);
            continue;
        }

        char *saveptr = NULL;
        char *given_token = strtok_r(buffer, " \t\r\n", &saveptr);
        char *command = strtok_r(NULL, " \t\r\n", &saveptr);
        char *arg = strtok_r(NULL, " \t\r\n", &saveptr);

        int rc = 64;
        if (given_token != NULL && command != NULL && strcmp(given_token, token) == 0) {
            rc = run_command(command, arg);
        } else {
            rc = 77;
        }

        char reply[32];
        snprintf(reply, sizeof(reply), "%d\n", rc);
        write(client, reply, strlen(reply));
        close(client);
    }

    close(server);
    unlink(socket_path);
    return 0;
}

int main(int argc, char **argv) {
    if (geteuid() != 0) {
        fprintf(stderr, "MSG fan helper must run as root\n");
        return 77;
    }
    if (argc < 2) return 64;
    if (!smc_open()) return 69;

    int rc;
    if (strcmp(argv[1], "serve") == 0 && argc >= 5) {
        uid_t owner_uid = (uid_t)strtoul(argv[4], NULL, 10);
        rc = serve(argv[2], argv[3], owner_uid);
    } else {
        rc = run_command(argv[1], argc >= 3 ? argv[2] : NULL);
    }

    smc_close();
    return rc;
}
