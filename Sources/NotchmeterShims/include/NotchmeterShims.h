#ifndef NOTCHMETER_SHIMS_H
#define NOTCHMETER_SHIMS_H

#include <stdbool.h>

/// Allows or suppresses the Keychain's access dialogs for this process. Wraps SecKeychainSetUserInteractionAllowed,
/// which is deprecated with no replacement for the file-based keychain's per-item access prompt.
void notchmeter_keychain_set_prompts_allowed(bool allowed);

#endif
