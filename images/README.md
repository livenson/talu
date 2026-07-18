# images — golden image pipeline

Containerfile-shaped builds (bootc-shaped): base cloud image + qemu-guest-agent +
cloud-init + serial console + (baked, disabled) bao-agent + platform CA root +
sshd `TrustedUserCAKeys`. **Bake capabilities, inject identity** — never bake a
secret. CI runs `virt-sparsify` + `cosign` and pushes a containerDisk to zot; a
`DataImportCron` imports on digest change and rolls the DataSource pointer.
Base image + registry URL are build inputs, not baked constants.
