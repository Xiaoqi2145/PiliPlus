import 'package:PiliPlus/models/common/enum_with_label.dart';

enum AudioOutput implements EnumWithLabel {
  // 顺序即 mpv --ao 的尝试优先级，必须是闭环后端在前。
  // aaudio / audiotrack 通过 AudioTrack.getTimestamp() / AAudioStream_getTimestamp()
  // 拿真实呈现位置，能自校正蓝牙传输延迟；opensles 是开环估算（固定 250ms 分片 +
  // 进程启动时读一次的 androidGetAudioLatency），蓝牙下会产生不受控的恒定偏置，
  // 故降到兜底位。aaudio 在 API<26 上 dlopen 失败会自动落到下一项，不会无声。
  aaudio('AAudio'),
  audiotrack('AudioTrack'),
  opensles('OpenSL ES'),
  ;

  static final defaultValue = values.map((e) => e.name).join(',');

  @override
  final String label;
  const AudioOutput(this.label);
}
