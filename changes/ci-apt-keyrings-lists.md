### Changed
- CI's check of the workflow also refuses a write into apt's keyrings (`/usr/share/keyrings/`, gpg's keyring there or under `/etc/apt/`) or lists (`/var/lib/apt/lists/`), a change into those folders, `APT::Key::` and `Acquire::gpgv` settings, and sees a write past `sudo -h <host>` and a `cd` or `pushd` past its options (#1024).
