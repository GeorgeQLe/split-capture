/******************************************************************************
    Copyright (C) 2026

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 2 of the License, or
    (at your option) any later version.
******************************************************************************/

#pragma once

#include "DualCaptureLogic.hpp"

#include <obs.hpp>
#include <obs-audio-controls.h>

#include <QDateTime>
#include <QString>

#include <memory>
#include <atomic>
#include <string>
#include <vector>

struct DualCaptureDevice {
	std::string sourceId;
	std::string property;
	std::string id;
	std::string name;
};

struct DualCaptureConfig {
	DualCaptureDevice desktop;
	DualCaptureDevice camera;
	DualCaptureDevice microphone;
	DualCaptureDevice systemAudio;
	std::string outputRoot;
	MicRoute micRoute = MicRoute::Both;
	bool desktopAudio = true;
	std::string videoEncoderId;
	uint32_t fpsNumerator = 30;
	uint32_t fpsDenominator = 1;
};

struct DualCaptureStats {
	uint64_t desktopBytes = 0;
	uint64_t cameraBytes = 0;
	int desktopDroppedFrames = 0;
	int cameraDroppedFrames = 0;
	int desktopTotalFrames = 0;
	int cameraTotalFrames = 0;
	qint64 elapsedMilliseconds = 0;
	int microphoneLevel = 0;
	int systemAudioLevel = 0;
};

class DualCaptureRecorder {
public:
	DualCaptureRecorder() = default;
	~DualCaptureRecorder();

	DualCaptureRecorder(const DualCaptureRecorder &) = delete;
	DualCaptureRecorder &operator=(const DualCaptureRecorder &) = delete;

	bool Start(const DualCaptureConfig &config, std::string &error);
	void Stop(const std::string &reason = "user");
	void CheckOutputs();
	void ShutdownTimedOut();

	bool Active() const;
	bool Busy() const;
	bool Stopping() const { return stopping; }
	bool UsedEncoderFallback() const { return encoderFallback; }
	DualCaptureStats Stats() const;
	const QString &SessionDirectory() const { return sessionDirectory; }
	const std::string &LastError() const { return lastError; }
	static bool SetTestFailpoint(const char *name);

private:
	enum Mixer : uint32_t {
		DesktopPlayback = 0,
		CameraPlayback = 1,
		IsolatedMicrophone = 2,
		IsolatedSystemAudio = 3,
	};

	struct RoleOutput {
		OBSSourceAutoRelease sceneSource;
		OBSSceneAutoRelease scene;
		OBSCanvasAutoRelease canvas;
		OBSOutputAutoRelease output;
		OBSEncoderAutoRelease videoEncoder;
		std::vector<OBSEncoderAutoRelease> audioEncoders;
		QString filename;
		uint32_t width = 0;
		uint32_t height = 0;
	};

	DualCaptureConfig currentConfig;
	OBSSourceAutoRelease desktopSource;
	OBSSourceAutoRelease cameraSource;
	OBSSourceAutoRelease microphoneSource;
	OBSSourceAutoRelease systemAudioSource;
	RoleOutput desktop;
	RoleOutput camera;
	std::shared_ptr<obs_encoder_group_t> encoderGroup;
	QString sessionDirectory;
	QString manifestPath;
	QString sessionId;
	QDateTime startedAt;
	bool stopping = false;
	bool initializationFailureCleanup = false;
	std::string pendingStopReason;
	bool encoderFallback = false;
	std::string lastError;
	std::atomic<int64_t> firstDesktopVideoNs{0};
	std::atomic<int64_t> firstCameraVideoNs{0};
	std::atomic<int> microphoneLevel{0};
	std::atomic<int> systemAudioLevel{0};
	obs_volmeter_t *microphoneVolmeter = nullptr;
	obs_volmeter_t *systemAudioVolmeter = nullptr;

	static OBSSourceAutoRelease CreateManagedSource(const DualCaptureDevice &device, const char *name,
							bool disableEmbeddedAudio);
	bool BuildRole(RoleOutput &role, obs_source_t *source, const char *roleName, uint32_t width, uint32_t height,
		       const std::string &encoderId, std::string &error);
	bool AddAudioEncoder(RoleOutput &role, uint32_t mixer, const char *name, std::string &error);
	void RouteAudio();
	void Clear();
	void FinishStop();
	void FinishInitializationFailure();
	void FailInitialization(const std::string &error);
	void WriteManifest(bool completed, const std::string &stopReason);
	static std::string OutputError(obs_output_t *output, const char *role, const char *fallback);
	static bool ConsumeTestFailpoint(DualCaptureTestFailpoint failpoint);
	static void CaptureFirstPacket(obs_output_t *output, encoder_packet *packet, encoder_packet_time *packetTime,
				       void *param);
	static void CaptureLevel(void *param, const float magnitude[MAX_AUDIO_CHANNELS],
				 const float peak[MAX_AUDIO_CHANNELS], const float inputPeak[MAX_AUDIO_CHANNELS]);
};
