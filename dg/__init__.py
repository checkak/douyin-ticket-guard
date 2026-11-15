"""douyin ticket guard —— 抖音演出票档监控 / 抢票工具。

模块：
  parse    cURL / HAR / 订单链接 → cookies + product_id
  api      get_show_sku_info 客户端 + 容错库存抽取
  engine   多任务轮询 / 阈值 / 去抖 / 全局 / 定时 / 日志
  notify   Bark 推送 + 铃响 + 深链拉起
  deeplink 深链构造与候选探测
"""
__version__ = "0.1.0"
