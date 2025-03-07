//
//  AudioDataManager.swift
//  SwiftAudioPlayer
//
//  Created by Tanha Kabir on 2019-01-29.
//  Copyright © 2019 Tanha Kabir, Jon Mercer
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.

import Foundation

protocol AudioDataManagable {
    var currentStreamFinished: Bool { get }
    var currentStreamFinishedWithDuration: Duration { get }
    var numberOfQueued: Int { get }
    var numberOfActive: Int { get }
    
    var allowCellular: Bool { get set }
    var downloadDirectory: FileManager.SearchPathDirectory { get }
    
    func setHTTPHeaderFields(_ fields: [String: String]?)
    func setBackgroundCompletionHandler(_ completionHandler: @escaping () -> ())
    func setAllowCellularDownloadPreference(_ preference: Bool)
    func setDownloadDirectory(_ dir: FileManager.SearchPathDirectory)
    
    func clear()
    func updateDuration(d: Duration)
    
    //Director pattern
    func attach(callback: @escaping (_ id: ID, _ progress: Double)->())
    
    func startStream(withRemoteURL url: AudioURL, callback: @escaping (StreamProgressPTO) -> ()) //called by throttler
    func pauseStream(withRemoteURL url: AudioURL)
    func resumeStream(withRemoteURL url: AudioURL)
    func seekStream(withRemoteURL url: AudioURL, toByteOffset offset: UInt64)
    func deleteStream(withRemoteURL url: AudioURL) 
    
    func getPersistedUrl(withRemoteURL url: AudioURL) -> URL?
    func getUrlKey(url: AudioURL) -> String
    func getAllStoredURLs() -> [URL]
    func startDownload(withRemoteURL url: AudioURL, completion: @escaping (URL, Error?) -> ())
    func cancelDownload(withRemoteURL url: AudioURL)
    func deleteDownload(withLocalURL url: URL)
}

class AudioDataManager: AudioDataManagable {
    var currentStreamFinishedWithDuration: Duration = 0

    var allowCellular: Bool = true
    var downloadDirectory: FileManager.SearchPathDirectory = .documentDirectory

    public var currentStreamFinished = false
    public var totalStreamedDuration = 0
    
    static let shared: AudioDataManagable = AudioDataManager()
    
    // When we're streaming we want to stagger the size of data push up from disk to prevent the phone from freezing. We push up data of this chunk size every couple milliseconds.
    private let MAXIMUM_DATA_SIZE_TO_PUSH = 37744
    private let TIME_IN_BETWEEN_STREAM_DATA_PUSH = 198
    
    var backgroundCompletion: ()-> Void = {} // set by AppDelegate
    
    //This is the first case where a DAO passes a closure to a singleon that receives delegate calls from the OS. When the delegate from the OS is called, this class calls the DAO's closure. We pretty much set up a stream from the delegate call to the director (and all the items subscribed to that director)
    private var globalDownloadProgressCallback: (String, Double)-> Void = {_,_ in }
    
    private var downloadWorker: AudioDataDownloadable!
    private var streamWorker: AudioDataStreamable!
    
    private var streamingCallbacks = [(ID, (StreamProgressPTO)->())]()
    
    private var originalDataCountForDownloadedAudio = 0
    
    var numberOfQueued: Int {
        return downloadWorker.numberOfQueued
    }
    
    var numberOfActive: Int {
        return downloadWorker.numberOfActive
    }
    
    private init() {
        downloadWorker = AudioDownloadWorker(
            allowCellular: allowCellular,
            progressCallback: downloadProgressListener,
            doneCallback: downloadDoneListener,
            backgroundDownloadCallback: backgroundCompletion)
        
        streamWorker = AudioStreamWorker(
            progressCallback: streamProgressListener,
            doneCallback: streamDoneListener)
    }

    func updateDuration(d: Duration) {
        currentStreamFinishedWithDuration = d
    }
    
    func clear() {
        streamingCallbacks = []
    }
    
    func setHTTPHeaderFields(_ fields: [String: String]?) {
        streamWorker.HTTPHeaderFields = fields
        downloadWorker.HTTPHeaderFields = fields
    }
    
    func setBackgroundCompletionHandler(_ completionHandler: @escaping () -> ()) {
        backgroundCompletion = completionHandler
    }
    
    func setAllowCellularDownloadPreference(_ preference: Bool) {
        allowCellular = preference
    }
    
    func setDownloadDirectory(_ dir: FileManager.SearchPathDirectory) {
        downloadDirectory = dir
    }
    
    func attach(callback: @escaping (_ id: ID, _ progress: Double)->()) {
        globalDownloadProgressCallback = callback
    }
}

// MARK:- Streaming
extension AudioDataManager {
    func startStream(withRemoteURL url: AudioURL, callback: @escaping (StreamProgressPTO) -> ()) {
        currentStreamFinished = false
        if let data = FileStorage.Audio.read(url.key) {
            let dto = StreamProgressDTO.init(progress: 1.0, data: data, totalBytesExpected: Int64(data.count))
            callback(StreamProgressPTO(dto: dto))
            return
        }
        
        let exists = streamingCallbacks.contains { (cb: (ID, (StreamProgressPTO) -> ())) -> Bool in
            return cb.0 == url.key
        }
        
        if !exists {
            streamingCallbacks.append((url.key, callback))
        }
        
        downloadWorker.stop(withID: url.key) { [weak self] (fetchedData: Data?, totalBytesExpected: Int64?) in
            self?.downloadWorker.pauseAllActive()
            self?.streamWorker.start(withID: url.key, withRemoteURL: url, withInitialData: fetchedData, andTotalBytesExpectedPreviously: totalBytesExpected)
        }
    }
    
    func pauseStream(withRemoteURL url: AudioURL) {
        guard streamWorker.getRunningID() == url.key else { return }
        streamWorker.pause(withId: url.key)
    }
    
    func resumeStream(withRemoteURL url: AudioURL) {
        streamWorker.resume(withId: url.key)
    }
    func seekStream(withRemoteURL url: AudioURL, toByteOffset offset: UInt64) {
        currentStreamFinished = false
        streamWorker.seek(withId: url.key, withByteOffset: offset)
    }
    
    func deleteStream(withRemoteURL url: AudioURL) {
        currentStreamFinished = false
        streamWorker.stop(withId: url.key)
        streamingCallbacks.removeAll { (cb: (ID, (StreamProgressPTO) -> ())) -> Bool in
            return cb.0 == url.key
        }
    }
}

// MARK:- Download
extension AudioDataManager {
    func getPersistedUrl(withRemoteURL url: AudioURL) -> URL? {
        return FileStorage.Audio.locate(url.key)
    }

    func getUrlKey(url: AudioURL) -> String {
        return url.key
    }

    func getAllStoredURLs() -> [URL] {
        return FileStorage.Audio.getAllStoredURLs()
    }
    
    func startDownload(withRemoteURL url: AudioURL, completion: @escaping (URL, Error?) -> ()) {
        let key = url.key
        
        if let savedUrl = FileStorage.Audio.locate(key), FileStorage.Audio.isStored(key) {
            globalDownloadProgressCallback(key, 1.0)
            completion(savedUrl, nil)
            return
        }
        
        if let currentProgress = downloadWorker.getProgressOfDownload(withID: key) {
            globalDownloadProgressCallback(key, currentProgress)
            return
        }
        
        // TODO: check if we already streaming and convert streaming to download when we have persistent play button
        guard streamWorker.getRunningID() != key else {
            Log.debug("already streaming audio, don't need to download key: \(key)")
            return
        }
        
        downloadWorker.start(withID: key, withRemoteUrl: url, completion: completion)
    }
    
    func cancelDownload(withRemoteURL url: AudioURL) {
        downloadWorker.stop(withID: url.key, callback: nil)
        FileStorage.Audio.delete(url.key)
    }
    
    func deleteDownload(withLocalURL url: URL) {
        FileStorage.delete(url)
    }
}

// MARK:- Listeners
extension AudioDataManager {
    private func downloadProgressListener(id: ID, progress: Double) {
        globalDownloadProgressCallback(id, progress)
    }
    
    private func streamProgressListener(id: ID, dto: StreamProgressDTO) {
        for c in streamingCallbacks {
            if c.0 == id {
                c.1(StreamProgressPTO(dto: dto))
            }
        }
    }
    
    private func downloadDoneListener(id: ID, error: Error?) {
        if error != nil {
            return
        }
        
        globalDownloadProgressCallback(id, 1.0)
    }
    
    private func streamDoneListener(id: ID, error: Error?) -> Bool {
        if error != nil {
            return false
        }
        currentStreamFinished = true
        downloadWorker.resumeAllActive()
        return false
    }
}


