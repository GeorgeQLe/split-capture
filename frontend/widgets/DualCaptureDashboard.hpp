/******************************************************************************
    Copyright (C) 2026

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 2 of the License, or
    (at your option) any later version.
******************************************************************************/

#pragma once

#include <utility/DualCaptureRecorder.hpp>

#include <QDialog>
#include <obs.hpp>

class QCheckBox;
class QComboBox;
class QLabel;
class QLineEdit;
class QProgressBar;
class QPushButton;
class QTimer;
class OBSBasic;
class OBSQTDisplay;

class DualCaptureDashboard : public QDialog {
public:
	explicit DualCaptureDashboard(OBSBasic *main);
	~DualCaptureDashboard() override;

	void OpenFocused();
	void Shutdown(int timeoutMilliseconds = 5000);

protected:
	void closeEvent(QCloseEvent *event) override;
	bool event(QEvent *event) override;

private:
	OBSBasic *main;
	QComboBox *desktopSelector;
	QComboBox *cameraSelector;
	QComboBox *microphoneSelector;
	QComboBox *routeSelector;
	QCheckBox *desktopAudio;
	QLineEdit *outputPath;
	QLabel *desktopStatus;
	QLabel *cameraStatus;
	QLabel *audioWarning;
	QLabel *storageEstimate;
	QLabel *recordingStats;
	QProgressBar *microphoneMeter;
	QProgressBar *systemMeter;
	QPushButton *browseButton;
	QPushButton *recordButton;
	QPushButton *advancedButton;
	QPushButton *screenPermissionButton;
	QPushButton *cameraPermissionButton;
	QPushButton *microphonePermissionButton;
	QTimer *timer;
	DualCaptureRecorder recorder;
	bool outputsDisabled = false;
	bool advancedRequested = false;
	bool screenPermissionRequested = false;
	DualCaptureShutdownLifecycle shutdownLifecycle;

	struct PreviewState {
		OBSQTDisplay *display = nullptr;
		OBSSourceAutoRelease source;
	};
	PreviewState desktopPreview;
	PreviewState cameraPreview;
	OBSSourceAutoRelease microphoneProbe;
	OBSSourceAutoRelease systemAudioProbe;
	obs_volmeter_t *microphoneProbeVolmeter = nullptr;
	obs_volmeter_t *systemAudioProbeVolmeter = nullptr;
	std::atomic<int> microphoneProbeLevel{0};
	std::atomic<int> systemAudioProbeLevel{0};

	void PopulateSources();
	void LoadSettings();
	void SaveSettings();
	void Browse();
	void RefreshReadiness();
	void ToggleRecording();
	void SetRecordingUi(bool recording);
	void UpdateStats();
	void UpdatePreviews();
	void ClearPreviews();
	void RebuildProbes();
	void ClearAudioProbes();
	void UpdatePermissionActions();
	static void DrawPreview(void *data, uint32_t width, uint32_t height);
	static void CaptureProbeLevel(void *param, const float magnitude[MAX_AUDIO_CHANNELS],
				      const float peak[MAX_AUDIO_CHANNELS], const float inputPeak[MAX_AUDIO_CHANNELS]);
	DualCaptureConfig CurrentConfig() const;
};
