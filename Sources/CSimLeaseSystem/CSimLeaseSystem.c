#include "CSimLeaseSystem.h"

#include <sys/file.h>

int simlease_flock(int descriptor, int operation) {
    return flock(descriptor, operation);
}
