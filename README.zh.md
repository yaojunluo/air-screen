# AirScreen

## 中文

### 项目简介

AirScreen 将您的 macOS 设备转化为 AirPlay 接收端，涵盖设备发现、RTSP 控制、RTP 传输、FairPlay 解密以及渲染等流程，可实现低延迟、高质量、音视频同步的实时镜像。

### 核心功能

- 通过 AirPlay 实现视频和音频的无线镜像，支持 FairPlay SAP 密钥交换保障安全
- 使用 VideoToolbox 结合自研 H.264 解包器实现高速低延迟的视频解码
- 基于 Metal 的渲染管线自动适配视频分辨率
- Bonjour 广播、RTSP 会话管理与 RTP 接收确保稳定的控制与传输
- 通过集成的 PlayFair C 库和 AES-128-CTR 解密处理 SAP 密钥与镜像流

### 技术栈

- 语言：Swift + SwiftUI
- 渲染：Metal + MetalKit
- 视频：VideoToolbox，H.264 解包 + 编码配置解析
- 音频：RTP 接收与同步播放
- 网络：Bonjour、RTSP、RTP、AES-128-CTR、FairPlay

### 截图

| 应用状态 | 描述 |
| --- | --- |
| ![应用就绪](public/start.png) | 应用处于待连接状态 |
| ![设备连接](public/connected.png) | iPhone 屏幕实时镜像到 Mac |

> Need English? [Switch to README.md](README.md)
