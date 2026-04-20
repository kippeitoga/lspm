#include "driver/i2s_std.h"
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

#define I2S_BCLK  17
#define I2S_WS    18
#define I2S_DIN   16

#define SAMPLE_RATE_HZ      16000 //16000から変更
#define DECIMATION_FACTOR   4 //sample_rate_hz 16000 4から変更（1000Hzが4だと５００、２だと２５０Hz）         // 16000 ÷ 4 = 4000Hz出力
#define OUTPUT_RATE_HZ      (SAMPLE_RATE_HZ / DECIMATION_FACTOR)
#define SAMPLES_PER_PACKET  160       // 160 ÷ 4000 = 40ms分

#define SERVICE_UUID           "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define CHARACTERISTIC_UUID_TX "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"

i2s_chan_handle_t   rx_chan;
BLEServer*          pServer           = nullptr;
BLECharacteristic*  pTxCharacteristic = nullptr;
bool                deviceConnected   = false;
QueueHandle_t       audioQueue;

class MyServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* pServer) override {
    deviceConnected = true;
  }
  void onDisconnect(BLEServer* pServer) override {
    deviceConnected = false;
    pServer->startAdvertising();
  }
};

void bleTask(void* pvParameters) {
  int16_t tx_buffer[SAMPLES_PER_PACKET];
  while (true) {
    if (xQueueReceive(audioQueue, tx_buffer, portMAX_DELAY) == pdPASS) {
      if (deviceConnected) {
        pTxCharacteristic->setValue(
          (uint8_t*)tx_buffer,
          sizeof(int16_t) * SAMPLES_PER_PACKET
        );
        pTxCharacteristic->notify();
        vTaskDelay(pdMS_TO_TICKS(38));
      }
    }
  }
}

void initI2S() {
  i2s_chan_config_t chan_cfg = I2S_CHANNEL_DEFAULT_CONFIG(I2S_NUM_0, I2S_ROLE_MASTER);
  chan_cfg.dma_desc_num  = 8;
  chan_cfg.dma_frame_num = 256;
  ESP_ERROR_CHECK(i2s_new_channel(&chan_cfg, NULL, &rx_chan));

  i2s_std_config_t std_cfg = {
    .clk_cfg  = I2S_STD_CLK_DEFAULT_CONFIG(SAMPLE_RATE_HZ),
    .slot_cfg = I2S_STD_PHILIPS_SLOT_DEFAULT_CONFIG(
      I2S_DATA_BIT_WIDTH_32BIT,
      I2S_SLOT_MODE_MONO
    ),
    .gpio_cfg = {
      .mclk = I2S_GPIO_UNUSED,
      .bclk = (gpio_num_t)I2S_BCLK,
      .ws   = (gpio_num_t)I2S_WS,
      .dout = I2S_GPIO_UNUSED,
      .din  = (gpio_num_t)I2S_DIN,
    }
  };
  ESP_ERROR_CHECK(i2s_channel_init_std_mode(rx_chan, &std_cfg));
  ESP_ERROR_CHECK(i2s_channel_enable(rx_chan));
}

void initBLE() {
  BLEDevice::init("ESP32_Stethoscope");
  BLEDevice::setMTU(512);
  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new MyServerCallbacks());
  BLEService* pService = pServer->createService(SERVICE_UUID);
  pTxCharacteristic = pService->createCharacteristic(
    CHARACTERISTIC_UUID_TX,
    BLECharacteristic::PROPERTY_NOTIFY
  );
  pTxCharacteristic->addDescriptor(new BLE2902());
  pService->start();
  pServer->getAdvertising()->start();
}

void setup() {
  Serial.begin(921600);
  delay(500);
  Serial.printf("SAMPLE_RATE_HZ    : %d\n", SAMPLE_RATE_HZ);
  Serial.printf("DECIMATION_FACTOR : %d\n", DECIMATION_FACTOR);
  Serial.printf("OUTPUT_RATE_HZ    : %d\n", OUTPUT_RATE_HZ);
  Serial.printf("SAMPLES_PER_PACKET: %d\n", SAMPLES_PER_PACKET);
  Serial.printf("vTaskDelay        : %d ms\n", 
    (SAMPLES_PER_PACKET * 1000 / OUTPUT_RATE_HZ) - 2);
  audioQueue = xQueueCreate(20, sizeof(int16_t) * SAMPLES_PER_PACKET);
  if (!audioQueue) { while (true) {} }
  initI2S();
  initBLE();
  xTaskCreatePinnedToCore(bleTask, "BLE_Task", 4096, NULL, 2, NULL, 0);
}

void loop() {
  static int32_t accumulator  = 0;
  static int     decim_count  = 0;
  static int32_t hpf_x_prev   = 0;
  static int32_t hpf_y_prev   = 0;
  static int16_t packet[SAMPLES_PER_PACKET];
  static int     packet_index  = 0;

  // LとRの2チャンネル分読む
  int32_t buf[2];
  size_t  bytes_read = 0;
  i2s_channel_read(rx_chan, buf, sizeof(buf), &bytes_read, portMAX_DELAY);
  if (bytes_read < sizeof(buf)) return;

  // Lチャンネルだけ使う（Rは常に0なので捨てる）
  int32_t sample = buf[0] >> 16;

  // ボックスフィルター（アンチエイリアス）
  accumulator += sample;
  decim_count++;
  if (decim_count < DECIMATION_FACTOR) return;

  int32_t averaged = accumulator / DECIMATION_FACTOR;
  accumulator = 0;
  decim_count = 0;

  /*
  ---------------------770Hzカット用に調整。
  // DCブロッキングフィルター（カットオフ約8Hz）
  int32_t hpf_out = averaged - hpf_x_prev + (hpf_y_prev * 1019) / 1024;
  hpf_x_prev = averaged;
  hpf_y_prev = hpf_out;

  // クランプ
  int32_t clamped = hpf_out;
  if (clamped >  32767) clamped =  32767;
  if (clamped < -32768) clamped = -32768;
  */
  // DCブロッキングフィルター（カットオフ約8Hz）
  int32_t hpf_out = averaged - hpf_x_prev + (hpf_y_prev * 1019) / 1024;
  hpf_x_prev = averaged;
  hpf_y_prev = hpf_out;

  // ノッチフィルター（770Hz除去）
  // fs=4000Hz, f0=770Hz, Q=10
  // w0 = 2π × 770/4000 = 1.2095rad
  // cos(w0) = 0.3518, sin(w0) = 0.9360
  // α = sin(w0)/(2Q) = 0.0468
  // b0 = b2 = 1/(1+α) × 1024 = 978
  // b1 = -2cos(w0)/(1+α) × 1024 = -688
  // a1 = -2cos(w0)/(1+α) × 1024 = -688  (b1と同じ)
  // a2 = (1-α)/(1+α) × 1024 = 933
  static int32_t notch_x1 = 0, notch_x2 = 0;
  static int32_t notch_y1 = 0, notch_y2 = 0;
  int32_t notch_out = (978 * hpf_out - 688 * notch_x1 + 978 * notch_x2
                     + 688 * notch_y1 - 933 * notch_y2) / 1024;
  notch_x2 = notch_x1;
  notch_x1 = hpf_out;
  notch_y2 = notch_y1;
  notch_y1 = notch_out;

  // クランプ
  int32_t clamped = notch_out;
  if (clamped >  32767) clamped =  32767;
  if (clamped < -32768) clamped = -32768;

  // キューに追加（溢れたら古いものを捨てる）
  packet[packet_index++] = (int16_t)clamped;
  if (packet_index >= SAMPLES_PER_PACKET) {
    if (xQueueSend(audioQueue, packet, 0) != pdPASS) {
      int16_t dummy[SAMPLES_PER_PACKET];
      xQueueReceive(audioQueue, dummy, 0);
      xQueueSend(audioQueue, packet, 0);
    }
    packet_index = 0;
  }
}
