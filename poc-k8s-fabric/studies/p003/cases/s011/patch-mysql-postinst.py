#!/usr/bin/env python3
"""Patch mysql-server-8.0.postinst stop_server() to treat a zombie (defunct)
mysqld as 'shut down'. In a container the daemonized temp mysqld becomes a
defunct zombie whose parent does not reap it promptly, so the original
`ps $pid` check keeps succeeding for ~180s and the postinst then fails,
leaving the package unconfigured. A zombie (state Z) or a gone process both
mean the server is effectively down."""
import sys

path = "/var/lib/dpkg/info/mysql-server-8.0.postinst"
old = (
    "    if ! $(ps $server_pid >/dev/null 2>&1); then\n"
    "      return 0\n"
    "    fi\n"
)
new = (
    "    local _st=$(ps -o state= -p $server_pid 2>/dev/null | tr -d ' \\n')\n"
    "    if [ -z \"$_st\" ] || [ \"$_st\" = \"Z\" ]; then\n"
    "      return 0\n"
    "    fi\n"
)
with open(path, "r") as f:
    content = f.read()
if old not in content:
    print("PATTERN_NOT_FOUND")
    sys.exit(2)
if new in content:
    print("ALREADY_PATCHED")
    sys.exit(0)
content = content.replace(old, new, 1)
with open(path, "w") as f:
    f.write(content)
print("PATCHED")
