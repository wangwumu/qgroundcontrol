#pragma once

#include "BaseClasses/VehicleTestManualConnect.h"

/// 参数**消费端**闸的用例：联网运营态（standaloneMode()==false）下收到 PARAM_VALUE 不得落地。
///
/// 背景：已有的两道闸（tryHashCheckCacheLoad / _startParameterDownload）都只挡"**发出**请求"这一侧，
/// 而 PARAM_VALUE 可以由**别的 GCS** 请求后经 mavp2p 下行扇出到达本机 —— 本机零上行却仍然收到帧
/// （2026-09-27 实测：本机无 msgid 20/21，仍收 720 条 PARAM_VALUE）。故闸必须补在消费端。
///
/// 三格结构：
///   阳性对照 Standalone_Consumed     —— 单例不存在 ⇒ standaloneModeEnabled()==true ⇒ 参数照常落地
///   差分点   OnlineMode_NotConsumed  —— 已登录 ⇒ standaloneMode()==false       ⇒ 参数不落地
///   阴性对照 OnlineMode_NoFrame      —— 已登录且不喂帧 ⇒ 不落地（排除"落地是别处造成的"）
class ParameterConsumeGateTest : public VehicleTestManualConnect
{
    Q_OBJECT

private slots:
    void cleanup() override;

    void _consumeGate_data();
    void _consumeGate();

private:
    /// present=true 时确保单例存在；false 时销毁它（析构会把 s_instance 清空）。
    /// AuthController::standaloneModeEnabled() 读的是单例，单例不存在 ⇒ 倒向"保留功能"(true)。
    static void _ensureAuthSingleton(bool present);
};
