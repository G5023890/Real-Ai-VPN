# Third-Party Notices

Real Ai Router implements no proprietary VPN protocol. It interoperates with
standard WireGuard and VLESS Reality configurations using the following
third-party components.

## WireGuard Apple

Copyright © 2018-2023 WireGuard LLC.

The WireGuard userspace adapter is licensed under the MIT License:

> Permission is hereby granted, free of charge, to any person obtaining a copy
> of this software and associated documentation files (the "Software"), to deal
> in the Software without restriction, including without limitation the rights
> to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
> copies of the Software, and to permit persons to whom the Software is
> furnished to do so, subject to the following conditions: the above copyright
> notice and this permission notice shall be included in all copies or
> substantial portions of the Software. THE SOFTWARE IS PROVIDED "AS IS",
> WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED.

Source: <https://git.zx2c4.com/wireguard-apple/>

## sing-box / Libbox

The VLESS Reality packet tunnel links the sing-box Libbox framework. sing-box is
licensed under GNU GPL version 3 or later. Corresponding source code and the
complete GPL text are available from the upstream project:

- Source: <https://github.com/SagerNet/sing-box>
- License: <https://www.gnu.org/licenses/gpl-3.0.html>

The Real Ai Router source, build scripts, and local changes required to combine
these components are published at <https://github.com/G5023890/Real-Ai-VPN>.

## Apple System Frameworks

NetworkExtension, Security, Network, and other Apple system frameworks are used
under the Apple SDK agreement. No Apple framework is redistributed separately.
