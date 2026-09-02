#include "NotchmeterShims.h"

#include <Security/Security.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
void notchmeter_keychain_set_prompts_allowed(bool allowed) {
    SecKeychainSetUserInteractionAllowed(allowed);
}
#pragma clang diagnostic pop
