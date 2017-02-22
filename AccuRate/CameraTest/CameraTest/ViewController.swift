//
//  ViewController.swift
//  CameraTest
//
//  Created by Grant Terrien on 9/30/16.
//  Copyright © 2016 com.terrien. All rights reserved.
//

import UIKit
import AVFoundation
import MessageUI
import HealthKit

public extension UIView {
    func fadeIn(withDuration duration: TimeInterval = 1.0) {
        UIView.animate(withDuration: duration, animations: {
            self.alpha = 1.0
        })
    }
}

class ViewController: UIViewController, UINavigationControllerDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, MFMailComposeViewControllerDelegate {
    
    var timer = Timer()
    
    func pulse() {
        DispatchQueue.main.async {
            self.heartView.alpha = 0.5
            self.heartView.fadeIn()
        }
    }
    
    let SCREEN_UPDATE_INTERVAL = 1.5 // How often we update the heart rate displayed on screen
    
    var startTime = TimeInterval()
    
    var captureDevice : AVCaptureDevice?
    var session : AVCaptureSession?
    
    var camCovered = false // is the camera covered?
    var lapsing = false; // is the camera not covered, but it's been less than a second?
    
    // Parameters for camera cover algorithm
    let MAX_LUMA_MEAN = Double(100)
    let MIN_LUMA_MEAN = Double(60)
    let MAX_LUMA_STD_DEV = Double(20)
    
    var stateQueue : YChannelStateQueue = YChannelStateQueue() // holds observations in order to calculate general derivative of brightness
    var brightnessDerivatives : [Int] = [Int]() // brightness derivatives origininating from YChannelStateQueue. The observations for our HMM
    var derivativeTimes : [Double] = [Double]() // timestamps for brightnessDerivatives. 1-to-1 correspondence between the two arrays.
    
    var beginningTime : Double = 0 // Beginning of last heart rate cycle
    
    // For heuristics and heart rate calculation
    var stateCount : Int = 0
    var bpmRecords : [Int] = [0,0,0,0,0,0]
    var HRCount : Int = 0
    var isFirstHR : Bool = true
    var lastCalculated : Date = Date()
    var previousBPM : Int = 0
    var camCoverStartTime : Double = 0
    var camCoverStartIndex : Int = 0
    var needToFindNextPeak : Bool = false
    var nextPeakIndex : Int = 0
    var tempObservation : [Int] = [Int]()
    var tempObsTime : [Double] = [Double]()
    var previousMeasuredBPM : Int = 0

    
    var currentBPM : Int = 0 // Master variable dictating what will be displayed
    var bpmTimer : Timer = Timer() // Controls when to update BPM displayed on screen
    var pulseTimer : Timer = Timer() // Controls visual pulsing of heart UI element
    
    
    // Initalizes state that must be reset when "STOP" is pressed or the app is loaded/navigated to.
    func initialize() {
        stateQueue = YChannelStateQueue()
        brightnessDerivatives = [Int]()
        derivativeTimes = [Double]()
        bpmRecords = [0,0,0,0,0,0]
        HRCount = 0
        isFirstHR = true
        previousBPM = 0
        camCoverStartTime = 0.0
        nextPeakIndex = 0
        tempObservation = []
        tempObsTime = []
        currentBPM = 0
        previousMeasuredBPM = 0
        startTime = NSDate.timeIntervalSinceReferenceDate
        timer = Timer()
    }
    
    // Stops/resets all UI elements and reinitializes variables
    func stop() {
        bpmTimer.invalidate()
        // End camera processes
        toggleFlashlight()
        session!.stopRunning()
        timer.invalidate()
        pulseTimer.invalidate()
        
        // Asynchronously update UI to initial state
        DispatchQueue.main.async {
            self.displayHeart(imageName: "Heart_inactive")
            self.heartView.removeFromSuperview()
            self.button.setBackgroundImage(UIImage(named: "Button_start"), for: UIControlState.normal)
            self.button.setTitle("START", for: UIControlState.normal)
            self.hint1.text = "Ready to start."
            self.hint2.text = "Please hit the START button."
            self.timerText.text = "00:00:00"
            self.BPMText.frame.size.width = 175
            self.BPMText.text = "- - - BPM"
        }
    }
    
    func displayHeart(imageName: String) {
        heartView = UIImageView(frame: CGRect(x: 0, y: 0, width: 170, height: 170))
        self.view.addSubview(heartView)
        heartView.translatesAutoresizingMaskIntoConstraints = false
        heartView.centerXAnchor.constraint(equalTo: view.centerXAnchor).isActive = true
        heartView.centerYAnchor.constraint(equalTo: view.centerYAnchor).isActive = true
        heartView.image = UIImage(named: imageName)
    }
    
    @IBOutlet var timerText: UILabel!
    @IBOutlet var button: UIButton!
    @IBOutlet var hint1: UILabel!
    @IBOutlet var hint2: UILabel!
    @IBOutlet var heartView: UIImageView!
    @IBOutlet var BPMText: UILabel!
    
    @IBAction func goInfo(_ sender: Any) {
        if button.currentTitle == "STOP" {
            session!.stopRunning()
            toggleFlashlight()
        }
    }
    
    // Update the screen with the current BPM
    func updateDisplayedBPM() {
        if self.currentBPM != 0 {
            DispatchQueue.main.async {
                self.BPMText.text = String(self.currentBPM) + " BPM"
                if self.currentBPM > 100 {
                    self.BPMText.frame.size.width = 190
                    self.heartView.removeFromSuperview()
                    self.displayHeart(imageName: "Heart_normal")
                    self.pulseTimer = Timer.scheduledTimer(timeInterval: 0.5, target: self, selector: #selector(ViewController.pulse), userInfo: nil, repeats: true)
                }
                else {
                    self.BPMText.frame.size.width = 160
                    self.heartView.removeFromSuperview()
                    self.displayHeart(imageName: "Heart_normal")
                    self.pulseTimer = Timer.scheduledTimer(timeInterval: 1.0, target: self, selector: #selector(ViewController.pulse), userInfo: nil, repeats: true)
                }
            }
        }
    }
    
    func start() {
        initialize()
        heartView.image = UIImage(named: "Heart_normal")
        heartView.alpha = 0.25
        heartView.fadeIn()
        button.setBackgroundImage(UIImage(named: "Button_stop"), for: UIControlState.normal)
        button.setTitle("STOP", for: UIControlState.normal)
        hint1.text = "Waiting for signal."
        hint2.text = "Please cover the camera with your finger."
        startCameraProcesses()
        bpmTimer = Timer.scheduledTimer(timeInterval: SCREEN_UPDATE_INTERVAL, target: self, selector: #selector(ViewController.updateDisplayedBPM), userInfo: nil, repeats: true)
        timer = Timer.scheduledTimer(timeInterval: 0.01, target: self, selector: #selector(ViewController.updateTime), userInfo: nil, repeats: true)
    }
    
    @IBAction func startStopButton(_ sender: AnyObject) {
        if button.currentTitle == "START" {
            start()
        }
        else {
            stop()
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        displayHeart(imageName: "Heart_inactive")
        initialize()
    }
    
    func toggleFlashlight() {
        captureDevice = AVCaptureDevice.defaultDevice(withMediaType: AVMediaTypeVideo) as AVCaptureDevice
        do {
            try captureDevice?.lockForConfiguration()
            if captureDevice?.torchMode == .on {
                captureDevice?.torchMode = .off
            } else {
                captureDevice?.torchMode = .on
            }
        } catch let error as NSError {
            NSLog("\(error)")
        }
    }
    
    // Initialize objects for using camera
    func startCameraProcesses() {
        captureDevice = AVCaptureDevice.defaultDevice(withMediaType: AVMediaTypeVideo) as AVCaptureDevice
        session = AVCaptureSession()
        session!.sessionPreset = AVCaptureSessionPresetHigh
        do {
            try captureDevice?.lockForConfiguration()
            captureDevice?.torchMode = .on
            captureDevice?.unlockForConfiguration()
            let deviceInput = try AVCaptureDeviceInput(device: captureDevice)
            session!.beginConfiguration()
            session!.addInput(deviceInput)
            let dataOutput = AVCaptureVideoDataOutput()
            dataOutput.videoSettings = [(kCVPixelBufferPixelFormatTypeKey as NSString) : NSNumber(value: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)]
            dataOutput.alwaysDiscardsLateVideoFrames = true
            session!.addOutput(dataOutput)
            session!.commitConfiguration()
            let queue = DispatchQueue(label: "queue")
            dataOutput.setSampleBufferDelegate(self, queue: queue)
            session!.startRunning()
            
        } catch let error as NSError {
            NSLog("\(error)")
        }
        
    }
    
    func updateDisplay() {
        if self.camCovered {
            hint1.text = "Signal detected!"
            hint2.text = "Please do not remove your finger from the camera."
        }
        else {
            heartView.removeFromSuperview()
            displayHeart(imageName: "Heart_normal")
            hint1.text = "Waiting for signal."
            hint2.text = "Please cover the camera with your finger."
            timerText.text = "00:00:00"
            BPMText.frame.size.width = 175
            BPMText.text = "- - - BPM"
        }
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }
    
    func getCoverageFromBrightness(lumaMean: Double, lumaStdDev: Double) -> Bool{
        if ((lumaMean < MAX_LUMA_MEAN) && (lumaMean > MIN_LUMA_MEAN) && (lumaStdDev < MAX_LUMA_STD_DEV)) {
            return true
        }
        return false
    }
    
    func captureOutput(_ captureOutput: AVCaptureOutput!, didOutputSampleBuffer sampleBuffer: CMSampleBuffer!, from connection: AVCaptureConnection!) {
        let buffer : CVPixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)!
        CVPixelBufferLockBaseAddress(buffer, CVPixelBufferLockFlags(rawValue: CVOptionFlags(0)))
        
        let baseAddress = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)
        let pointer = baseAddress?.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let byteBuffer = UnsafeMutablePointer<UInt8>(pointer)!
        
        let mean = detectFingerCoverage(bytesPerRow: bytesPerRow, byteBuffer: byteBuffer)
        
        if self.camCovered {
            useCaptureOutputForHeartRateEstimation(mean: mean, bytesPerRow: bytesPerRow)
        }
    }
    
    func getMeanAndStdDev(bytesPerRow: Int, byteBuffer: UnsafeMutablePointer<UInt8>) -> (Double, Double){
        var sum = 0
        let pixels = 1080 * bytesPerRow
        for index in 0...pixels-1 {
            sum += Int(byteBuffer[index])
        }
        let mean = (Double(sum)/Double(pixels))
        
        var sqrdDiffs = 0.0
        for index in 0...pixels-1 {
            let sqrdDiff = (Double(byteBuffer[index]) - mean) * (Double(byteBuffer[index]) - mean)
            sqrdDiffs += sqrdDiff
        }
        let stdDev = sqrt((Double(sqrdDiffs)/Double(pixels)))
        
        return (mean, stdDev);
    }
    
    func detectFingerCoverage(bytesPerRow: Int, byteBuffer: UnsafeMutablePointer<UInt8>) -> Double {
        
        let meanAndStdDev = getMeanAndStdDev(bytesPerRow: bytesPerRow, byteBuffer: byteBuffer)
        
        let mean = meanAndStdDev.0
        let stdDev = meanAndStdDev.1
        
        let covered = getCoverageFromBrightness(lumaMean: mean, lumaStdDev: stdDev)
        
        DispatchQueue.main.async {
            if covered != self.camCovered {
                self.camCovered = covered
                if !self.camCovered && !self.lapsing {
                    self.lapsing = true;
                    DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(1), execute: {
                        if !self.camCovered && self.button.currentTitle == "STOP" {
                            self.updateDisplay()
                        }
                        self.lapsing = false;
                    })
                } else if !self.lapsing && self.button.currentTitle == "STOP" {
                    self.updateDisplay()
                }
            }
        }
        return mean
    }
    
    func updateTime() {
        DispatchQueue.main.async {
            let currentTime = NSDate.timeIntervalSinceReferenceDate
            //Find the difference between current time and start time.
            var elapsedTime: TimeInterval = currentTime - self.startTime
            if elapsedTime > 8000000 { // To fix underflow error that causes wonky display in line above
                elapsedTime = 0
            }
            //Calculate the minutes in elapsed time.
            let minutes = UInt32(elapsedTime / 60.0)
            elapsedTime -= (TimeInterval(minutes) * 60)
            //Calculate the seconds in elapsed time.
            let seconds = UInt32(elapsedTime)
            elapsedTime -= TimeInterval(seconds)
            //Find out the fraction of milliseconds to be displayed.
            let fraction = UInt32(elapsedTime * 100)
            //Add the leading zero for minutes, seconds and millseconds and store them as string constants
            let strMinutes = String(format: "%02d", minutes)
            let strSeconds = String(format: "%02d", seconds)
            let strFraction = String(format: "%02d", fraction)
            //Concatenate minuets, seconds and milliseconds as assign it to the UILabel
            self.timerText.text = "\(strMinutes):\(strSeconds):\(strFraction)"
        }
    }
    
    
    //****************** Viterbi and heart rate estimation *********************
    
    func viterbi(obs:Array<Int>, trans:Array<Array<Double>>, emit:Array<Array<Double>>, states: Array<Int>, initial:Array<Double>)->(Double, [Int]){
        
        var vit = [[Int:Double]()]
        var path = [Int:[Int]]()
        
        for s in states{
            vit[0][s] = initial[s] * emit[s][obs[0]]
            path[s] = [s]
        }
        for i in 1..<obs.count{
            vit.append([:])
            var newPath = [Int:[Int]]()
            
            for state1 in states{
                var transMax = DBL_MIN
                var maxProb = DBL_MIN
                var bestState : Int = 0
                
                for state2 in states{
                    if vit[i-1][state2] == nil {
                        vit[i-1][state2] = 0.0
                    }
                    let transProb = vit[i-1][state2]! * trans[state2][state1]
                    if transProb > transMax{
                        transMax = transProb
                        maxProb = transMax * emit[state1][obs[i]]
                        vit[i][state1] = maxProb
                        bestState = state2
                        newPath[state1] = path[bestState]! + [state1]
                    }
                }
                
            }
            path = newPath
        }
        let len = obs.count - 1
        var bestState:Int = 0
        var maxProb = DBL_MIN
        for state in states{
            if vit[len][state] == nil {
                vit[len][state] = 0.0
            }
            if vit[len][state]! > maxProb{
                maxProb = vit[len][state]!
                bestState = state
            }
        }
        return (maxProb, path[bestState]!)
        
    }
    
    func calculate(states:Array<Int>){
        var previous = states[0]
        var validBPM = 0
        var tempBPM = 0
        var interval = 0.0
        
        for i in 0..<states.count{
            if (states[i]==0 && previous == 3) {
                if beginningTime != 0 {
                    interval = (derivativeTimes[i]) - beginningTime
                    validBPM = Int(60 / interval)
                    if ((validBPM > 30) && (validBPM < 300)) || HRCount == 0{

                        bpmRecords[HRCount % 6] = validBPM
                    } else {
                        bpmRecords[HRCount % 6] = bpmRecords[(HRCount-1) % 6]
                    }
                    bpmRecords[HRCount % 6] = validBPM
                    if HRCount >= 6{
                        tempBPM = (validBPM + previousBPM)/2
                        var avg:Double = 0
                        var sum:Double = 0
                        var tempRecords = bpmRecords.sorted()
                        print("array: ", tempRecords)
                        for k in 1..<5{
                            sum = sum + Double((tempRecords[k]))
                        }
                        avg = sum/3
                        var usefulEnds:Int = 0
                        if abs(Double((tempRecords[0])) - avg)<=10{
                            sum = sum + Double((tempRecords[0]))
                            usefulEnds += 1
                        }
                        if abs(Double((tempRecords[5])) - avg)<=10{
                            sum = sum + Double((tempRecords[5]))
                            usefulEnds += 1
                        }
                        avg = sum / Double(4 + usefulEnds)
                        print("previous: ", previousBPM, " avg: ", avg)
                        if (abs(tempBPM - previousBPM) <= 10)
                            && (tempBPM >= 30) && (tempBPM <= 300) {
                            validBPM = (((tempRecords[2])+(tempRecords[3])+tempBPM) / 3 + previousBPM) / 2
                            
                            
                        } else {
                            validBPM = Int(avg)
                        }
                        previousBPM = validBPM
                        self.currentBPM = validBPM
                        
                        print("we choose: ", currentBPM)
                        
                        // Check if the standard deviation of bpm measurements is low
                        // if so, stop and ask the user if they want to import to HealthKit
                        let standardDeviation = self.calculateStandardDeviationOfIntArray(array: tempRecords)
                        if standardDeviation < 10 && HKHealthStore.isHealthDataAvailable() {
                            self.stop() // change to STOP and RESET UI method
                            self.showHeartRateMeasuredDialog(UIButton())
                        }
                    } else{
                        if ((30<=validBPM)&&(validBPM<=300)){
                            previousBPM = validBPM
                        }
                        
                    }
                    HRCount = HRCount + 1
                }
                
                beginningTime = derivativeTimes[i]
                
            }
            
            
            previous = states[i]
        }
    }
    
    func calculateStandardDeviationOfIntArray(array: [Int]) -> Double {
        // Calculate standard deviation of values in array
        var meanOfAllCurrentMeasurements = 0
        for i in 0..<array.count {
            meanOfAllCurrentMeasurements += array[i]
        }
        meanOfAllCurrentMeasurements = meanOfAllCurrentMeasurements/array.count
        var standardDeviation : Double = 0
        for i in 0..<array.count {
            let squaredDiff = (Double(array[i]-meanOfAllCurrentMeasurements))*(Double(array[i]-meanOfAllCurrentMeasurements))
            standardDeviation += squaredDiff
        }
        standardDeviation = sqrt(standardDeviation/Double(array.count))
        
        return standardDeviation
    }
    
    @IBAction func showHeartRateMeasuredDialog(_ sender: UIButton) {
        DispatchQueue.main.async {
            // create the alert
            let alert = UIAlertController(title: "Your heart rate is " + String(self.currentBPM) + " BPM", message: "Save to Apple Health?", preferredStyle: UIAlertControllerStyle.alert)
            
            // add an action (button)
            alert.addAction(UIAlertAction(title: "Save", style: UIAlertActionStyle.default, handler: {action in self.saveHeartData(bpm: self.currentBPM)}))
            
            alert.addAction(UIAlertAction(title: "Cancel", style: UIAlertActionStyle.cancel, handler: nil))
            
            // show the alert
            self.present(alert, animated: true, completion: nil)
        }
    }
    
    func saveHeartData(bpm : Int) {
        let healthKitTypes: Set = [HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier.heartRate)!]
        let healthStore = HKHealthStore()
        healthStore.requestAuthorization(toShare: healthKitTypes, read: nil) { (success, error) -> Void in }
        
        // 1. Create a heart rate BPM Sample
        let heartRateType = HKQuantityType.quantityType(forIdentifier: HKQuantityTypeIdentifier.heartRate)!
        let heartRateQuantity = HKQuantity(unit: HKUnit(from: "count/min"),
                                           doubleValue: Double(bpm))
        let heartSample = HKQuantitySample(type: heartRateType,
                                           quantity: heartRateQuantity, start: NSDate() as Date, end: NSDate() as Date)
        
        // 2. Save the sample in the store
        healthStore.save(heartSample, withCompletion: { (success, error) -> Void in
            if let error = error {
                print("Error saving heart sample: \(error.localizedDescription)")
            }
        })
    }

    
    
    func useCaptureOutputForHeartRateEstimation(mean: Double, bytesPerRow: Int) {
        let currentTime = NSDate().timeIntervalSince1970
        let states = [0,1,2,3]

        
        // BayesHeart Matrices
//        let trans = [[0.6794, 0.3206, 0.0, 0.0],
//                     [0.0, 0.5366, 0.4634, 0.0],
//                     [0.0, 0.0, 0.3485, 0.6516],
//                     [0.1508, 0.0, 0.0, 0.8492]]
//        
//        let emit = [[0.6884, 0.0015, 0.3002, 0.0099],
//                    [0.0, 0.7205, 0.0102, 0.2694],
//                    [0.2894, 0.3731, 0.3362, 0.0023],
//                    [0.0005, 0.8440, 0.0021, 0.1534]]
//        let p = [0.25, 0.20, 0.10, 0.45]
        
        // our matrices (with BayesHeart as initial)
        let trans = [[0.81196025,  0.18803975,  0.0,  0.0],
            [ 0.0,  0.0,  1.0,  0.0],
            [ 0.0,  0.0,  0.38188347,  0.61811653],
            [ 1.0,  0.0,  0.0,  0.0]]
        
        let emit = [[ 0.86449806,  0.0023080861,  0.066598702,  0.066595155],
            [ 0.0,  0.016592151,  0.98340785,  0.0],
            [ 0.0,  1.0,  0.0,  0.0],
            [ 0.0,  0.016573281,  0.0,  0.98342672]]
        
        let p = [1.0, 0.0, 0.0, 0.0]
        
        // Trained from vanilla
//        let trans = [[ 0.73051926,  0.26948074,  0.0,  0.0],
//            [ 0.0,  0.0,  1.0,  0.0],
//            [ 0.0,  0.0,  0.47706229,  0.52293771],
//            [ 1.0,  0.0,  0.0,  0.0]]
//        
//        let emit = [[ 1.0,  0.0,  0.0,  0.0],
//            [ 0.084427546,  0.0,  0.91557245,  0.0],
//            [ 0.019529611,  0.74125375,  0.1181616,  0.12105504],
//            [ 0.091452405,  0.0,  0.0,  0.9085476]]
//        
//        
//        let p = [ 0.0,  0.0,  1.0,  0.0]
        
        if (self.camCovered) {
            let pixels = 1080 * bytesPerRow
            let value = mean/Double(pixels)
            stateQueue.addValue(value: value)
            if (self.tempObservation.count != 0){
                if (((tempObsTime.last!) - (tempObsTime.first!)) >= 2.0) {
                    for i in 0..<self.tempObservation.count {
                        if (((tempObsTime.last!) - (tempObsTime[self.tempObsTime.count - i - 1])) >= 1.0) {
                            self.brightnessDerivatives = self.brightnessDerivatives + tempObservation
                            self.derivativeTimes = self.derivativeTimes + tempObsTime
                        } else {
                            self.tempObsTime.removeLast(i)
                            self.tempObservation.removeLast(i)
                        }
                    }
                }
                tempObsTime = []
                tempObservation = []
            }
            self.camCoverStartTime = currentTime
            self.needToFindNextPeak = true
            if (self.brightnessDerivatives.count != 0){
                if (((self.derivativeTimes.last)! - (self.derivativeTimes.first)!) >= 3.0){
                    if (((self.derivativeTimes.last)! - (self.derivativeTimes.first)!) >= 20 && self.brightnessDerivatives.count > 200 && self.derivativeTimes.count > 200){
                        let temp1 = self.brightnessDerivatives[200..<self.brightnessDerivatives.count]
                        self.brightnessDerivatives = Array(temp1)
                        let temp2 = self.derivativeTimes[200..<self.derivativeTimes.count]
                        self.derivativeTimes = Array(temp2)
                        
                    }
                    self.calculate(states: self.viterbi(obs:self.brightnessDerivatives, trans:trans, emit:emit, states:states, initial:p).1)
                }
            }
            
            self.tempObservation.append((stateQueue.getState()))
            self.tempObsTime.append(currentTime)
            if (needToFindNextPeak) {
                if ((currentTime - self.camCoverStartTime) >= 1.0) {
                    self.needToFindNextPeak = false
                } else {
                    tempObsTime = [(tempObsTime.last!)]
                    tempObservation = [(tempObservation.last!)]
                }
                
            }
            
            if (stateQueue.getState() != -1) {
                derivativeTimes.append(NSDate().timeIntervalSince1970)
                brightnessDerivatives.append((stateQueue.getState()))
            }
            
        }
    }
}
