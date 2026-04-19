"""
ICBHI Respiratory Sound Database を使った wheeze vs normal の2値分類（最小構成）。

ラベル:
  - txt の各行は「開始秒, 終了秒, crackle(0/1), wheeze(0/1)」
  - いずれかの行で wheeze=1 → positive（wheeze あり）
  - すべての行で wheeze=0 かつ crackle=0 → negative（normal）
  - wheeze はないがどこかで crackle=1 だけ → crackle-only として除外

train / test:
  - ファイル名先頭の患者 ID（例: 101_1b1_Al_sc_Meditron.wav → 101）単位で分割
  - 同一患者の録音は train と test の両方に入らない（患者リーク防止）
"""

from __future__ import annotations

import random
from collections import defaultdict
from pathlib import Path

import librosa
import numpy as np
import torch
import torch.nn as nn
from torch.utils.data import DataLoader, Dataset

# ---------------------------------------------------------------------------
# 設定（必要ならここだけ変えればよい）
# ---------------------------------------------------------------------------

# このスクリプトと同じ場所からの相対パス（データ配置に合わせてある）
DATA_ROOT = Path(__file__).resolve().parent / "data" / "Respiratory_Sound_Database"
AUDIO_DIR = DATA_ROOT / "audio_and_txt_files"

TARGET_SR = 2000
# 波形をこの長さに揃える（長い場合は先頭から切り詰め、短い場合はゼロ埋め）
MAX_AUDIO_SEC = 20.0

N_MELS = 64
N_FFT = 512
HOP_LENGTH = 256

BATCH_SIZE = 8
EPOCHS = 5
LEARNING_RATE = 1e-3
TEST_RATIO = 0.2
RANDOM_SEED = 42


def patient_id_from_wav(wav_path: Path) -> str:
    """ICBHI ファイル名の先頭が患者番号（例: 101_1b1_Al_sc_Meditron.wav → '101'）。"""
    return wav_path.stem.split("_", 1)[0]


def label_from_txt(txt_path: Path) -> int | None:
    """
    アノテーションファイルからラベルを決める。
    戻り値: 0 = normal, 1 = wheeze, None = 学習に使わない（crackle-only など）
    """
    has_wheeze = False
    has_crackle = False
    text = txt_path.read_text(encoding="utf-8", errors="ignore")
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.replace("\t", " ").split()
        if len(parts) < 4:
            continue
        crackle = int(float(parts[2]))
        wheeze = int(float(parts[3]))
        if wheeze == 1:
            has_wheeze = True
        if crackle == 1:
            has_crackle = True

    if has_wheeze:
        return 1
    if has_crackle:
        # wheeze は一度も出てこないのに crackle だけある → 今回は除外
        return None
    return 0


def load_wav_paths_and_labels() -> tuple[list[Path], list[int]]:
    """使う wav ファイルとラベルのリストを作る。"""
    wav_paths: list[Path] = []
    labels: list[int] = []
    for wav_path in sorted(AUDIO_DIR.glob("*.wav")):
        txt_path = wav_path.with_suffix(".txt")
        if not txt_path.is_file():
            continue
        label = label_from_txt(txt_path)
        if label is None:
            continue
        wav_paths.append(wav_path)
        labels.append(label)
    return wav_paths, labels


def split_train_test_by_patient(
    wav_paths: list[Path],
    labels: list[int],
    test_ratio: float,
    seed: int,
) -> tuple[list[Path], list[int], list[Path], list[int]]:
    """
    患者 ID 単位で train / test に分ける。
    同じ患者のファイルは必ずどちらか一方のセットだけに入る。
    """
    rng = random.Random(seed)
    by_patient: dict[str, list[tuple[Path, int]]] = defaultdict(list)
    for wav_path, label in zip(wav_paths, labels):
        by_patient[patient_id_from_wav(wav_path)].append((wav_path, label))

    patient_ids = list(by_patient.keys())
    rng.shuffle(patient_ids)
    n_pat = len(patient_ids)

    if n_pat < 2:
        raise RuntimeError(
            "患者が1人だけのため、患者単位で train/test に分けられません。"
            "データセットを確認してください。"
        )

    n_test = int(round(n_pat * test_ratio))
    n_test = max(1, min(n_test, n_pat - 1))

    test_pids = set(patient_ids[:n_test])
    train_pids = set(patient_ids[n_test:])

    train_paths: list[Path] = []
    train_labels: list[int] = []
    test_paths: list[Path] = []
    test_labels: list[int] = []

    for pid in train_pids:
        for p, y in by_patient[pid]:
            train_paths.append(p)
            train_labels.append(y)
    for pid in test_pids:
        for p, y in by_patient[pid]:
            test_paths.append(p)
            test_labels.append(y)

    order = list(range(len(train_paths)))
    rng.shuffle(order)
    train_paths = [train_paths[i] for i in order]
    train_labels = [train_labels[i] for i in order]

    return train_paths, train_labels, test_paths, test_labels


def binary_classification_metrics(
    y_true: list[int], y_pred: list[int]
) -> tuple[float, float, float, float, np.ndarray]:
    """
    2値分類（0=normal, 1=wheeze）の指標。
    precision / recall / f1 は positive（wheeze=1）について。
    confusion matrix は行=真のラベル、列=予測（0,1 の順）。
    """
    yt = np.asarray(y_true, dtype=np.int64)
    yp = np.asarray(y_pred, dtype=np.int64)
    tp = int(np.sum((yt == 1) & (yp == 1)))
    tn = int(np.sum((yt == 0) & (yp == 0)))
    fp = int(np.sum((yt == 0) & (yp == 1)))
    fn = int(np.sum((yt == 1) & (yp == 0)))
    n = tp + tn + fp + fn
    accuracy = (tp + tn) / n if n else 0.0
    precision = tp / (tp + fp) if (tp + fp) else 0.0
    recall = tp / (tp + fn) if (tp + fn) else 0.0
    if precision + recall == 0:
        f1 = 0.0
    else:
        f1 = 2.0 * precision * recall / (precision + recall)
    # [[TN, FP], [FN, TP]]  … 行が真 0/1、列が予測 0/1
    cm = np.array([[tn, fp], [fn, tp]], dtype=np.int64)
    return accuracy, precision, recall, f1, cm


class RespiratoryWheezeDataset(Dataset):
    """wav を読み、log-mel spectrogram とラベルを返す。"""

    def __init__(self, wav_paths: list[Path], labels: list[int]) -> None:
        self.wav_paths = wav_paths
        self.labels = labels
        self.max_samples = int(TARGET_SR * MAX_AUDIO_SEC)

    def __len__(self) -> int:
        return len(self.wav_paths)

    def __getitem__(self, index: int) -> tuple[torch.Tensor, torch.Tensor]:
        wav_path = self.wav_paths[index]
        label = self.labels[index]

        # mono, 指定サンプルレートにリサンプル
        y, _ = librosa.load(wav_path, sr=TARGET_SR, mono=True)

        # 長さを揃える
        if len(y) > self.max_samples:
            y = y[: self.max_samples]
        elif len(y) < self.max_samples:
            y = np.pad(y, (0, self.max_samples - len(y)))

        mel = librosa.feature.melspectrogram(
            y=y,
            sr=TARGET_SR,
            n_fft=N_FFT,
            hop_length=HOP_LENGTH,
            n_mels=N_MELS,
            power=2.0,
        )
        log_mel = np.log(mel + 1e-6).astype(np.float32)

        # PyTorch の Conv2d は (チャネル, 高さ, 幅) → (1, n_mels, 時間フレーム)
        x = torch.from_numpy(log_mel).unsqueeze(0)
        y_tensor = torch.tensor(label, dtype=torch.long)
        return x, y_tensor


class SmallCNN(nn.Module):
    """とても小さな CNN（動くことを優先）。"""

    def __init__(self, n_mels: int, n_frames: int) -> None:
        super().__init__()
        self.features = nn.Sequential(
            nn.Conv2d(1, 16, kernel_size=3, padding=1),
            nn.ReLU(inplace=True),
            nn.MaxPool2d(2),
            nn.Conv2d(16, 32, kernel_size=3, padding=1),
            nn.ReLU(inplace=True),
            nn.MaxPool2d(2),
            nn.Conv2d(32, 64, kernel_size=3, padding=1),
            nn.ReLU(inplace=True),
        )
        # 一度ダミーで畳み込み後のサイズを計算して全結合層の入力次元を決める
        with torch.no_grad():
            dummy = torch.zeros(1, 1, n_mels, n_frames)
            out = self.features(dummy)
            flat_dim = int(out.numel())

        self.classifier = nn.Sequential(
            nn.Flatten(),
            nn.Linear(flat_dim, 64),
            nn.ReLU(inplace=True),
            nn.Linear(64, 2),
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = self.features(x)
        return self.classifier(x)


def mel_frame_count() -> int:
    """固定長波形に対する mel の時間フレーム数（librosa と同じ前提）。"""
    max_samples = int(TARGET_SR * MAX_AUDIO_SEC)
    mel = librosa.feature.melspectrogram(
        y=np.zeros(max_samples, dtype=np.float32),
        sr=TARGET_SR,
        n_fft=N_FFT,
        hop_length=HOP_LENGTH,
        n_mels=N_MELS,
        power=2.0,
    )
    return mel.shape[1]


def main() -> None:
    if not AUDIO_DIR.is_dir():
        raise FileNotFoundError(
            f"データフォルダが見つかりません: {AUDIO_DIR}\n"
            "ICBHI の Respiratory_Sound_Database を ml/data/ に置いてください。"
        )

    torch.manual_seed(RANDOM_SEED)
    np.random.seed(RANDOM_SEED)
    random.seed(RANDOM_SEED)

    wav_paths, labels = load_wav_paths_and_labels()
    n_pos = sum(1 for y in labels if y == 1)
    n_neg = sum(1 for y in labels if y == 0)
    n_patients = len({patient_id_from_wav(p) for p in wav_paths})
    print(
        f"使用するファイル数: {len(wav_paths)} "
        f"(患者数={n_patients}, wheeze={n_pos}, normal={n_neg}, crackle-only は除外済み)"
    )

    train_paths, train_labels, test_paths, test_labels = split_train_test_by_patient(
        wav_paths, labels, TEST_RATIO, RANDOM_SEED
    )
    n_train_pat = len({patient_id_from_wav(p) for p in train_paths})
    n_test_pat = len({patient_id_from_wav(p) for p in test_paths})
    print(
        f"train: {len(train_paths)} ファイル / {n_train_pat} 患者, "
        f"test: {len(test_paths)} ファイル / {n_test_pat} 患者（患者単位分割）"
    )

    n_frames = mel_frame_count()
    train_ds = RespiratoryWheezeDataset(train_paths, train_labels)
    test_ds = RespiratoryWheezeDataset(test_paths, test_labels)
    train_loader = DataLoader(train_ds, batch_size=BATCH_SIZE, shuffle=True)
    test_loader = DataLoader(test_ds, batch_size=BATCH_SIZE, shuffle=False)

    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    model = SmallCNN(N_MELS, n_frames).to(device)
    criterion = nn.CrossEntropyLoss()
    optimizer = torch.optim.Adam(model.parameters(), lr=LEARNING_RATE)

    for epoch in range(1, EPOCHS + 1):
        model.train()
        running_loss = 0.0
        for xb, yb in train_loader:
            xb = xb.to(device)
            yb = yb.to(device)
            optimizer.zero_grad()
            logits = model(xb)
            loss = criterion(logits, yb)
            loss.backward()
            optimizer.step()
            running_loss += loss.item() * xb.size(0)
        avg_loss = running_loss / len(train_loader.dataset)
        print(f"epoch {epoch}/{EPOCHS}  train loss: {avg_loss:.4f}")

    model.eval()
    all_true: list[int] = []
    all_pred: list[int] = []
    with torch.no_grad():
        for xb, yb in test_loader:
            xb = xb.to(device)
            logits = model(xb)
            preds = logits.argmax(dim=1).cpu().numpy().tolist()
            all_pred.extend(preds)
            all_true.extend(yb.numpy().tolist())

    acc, prec, rec, f1, cm = binary_classification_metrics(all_true, all_pred)
    print("--- test 評価（positive = wheeze） ---")
    print(f"accuracy:  {acc:.4f}")
    print(f"precision: {prec:.4f}")
    print(f"recall:    {rec:.4f}")
    print(f"f1:        {f1:.4f}")
    print("confusion matrix [行=真のラベル 0=normal,1=wheeze / 列=予測 0,1]:")
    print(cm)

    out_path = Path(__file__).resolve().parent / "model.pth"
    torch.save(model.state_dict(), out_path)
    print(f"保存しました: {out_path}")


if __name__ == "__main__":
    main()

# ---------------------------------------------------------------------------
# 実行例（ターミナル）:
#
#   cd /Users/kippeitoga/Documents/lung-monitor-mvp/ml
#   python3 -m venv venv
#   source venv/bin/activate          # Windows の場合: venv\Scripts\activate
#   pip install torch librosa numpy soundfile
#
#   python train.py
#
# 学習後、同じフォルダに model.pth ができます。
# ---------------------------------------------------------------------------
