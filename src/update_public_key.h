#pragma once

// Public half of the offline firmware release key. The private key lives at
// ~/.config/claude-rlcd/firmware-signing-key.pem and must never be committed.
static const char UPDATE_PUBLIC_KEY[] = R"KEY(-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEUze9eR4OdLKH8wzi51Mgtnz2qkiz
qv8cwxJSBkEzAV4Aot1AzVOQIkjVC03Ux1VcfLC+C1NMNDY2nsExLZC/hw==
-----END PUBLIC KEY-----
)KEY";
