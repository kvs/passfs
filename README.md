# passfs

Protects your sensitive files from unwanted access.

## How it works

By running a shadow filesystem, and symlinking protected files into your regular filesystem.
Once a protected file is accessed, a passphrase will be required to decrypt the file.

Behind the scenes, this is all handled by GnuPG and its pinentry-program.

## Requirements

* GnuPG v2 for encrypting and decrypting
* pinentry or pinentry-mac, for passphrase entry
* a running gpg-agent
* FUSE
