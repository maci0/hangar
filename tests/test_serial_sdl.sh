#!/bin/bash
qemu-system-x86_64 -machine q35 -m 512 -display sdl -serial unix:/tmp/kvmgui-serial-test_vm.sock,server=on,wait=off &
sleep 1
cat < /tmp/kvmgui-serial-test_vm.sock &
kill -9 %2
kill -9 %1
