//
//  ViewController.swift
//  CameraTest
//
//  Created by Grant Terrien on 9/30/16.
//  Copyright © 2016 com.terrien. All rights reserved.
//

import UIKit
import AVFoundation

public extension UIView {
    func fadeIn(withDuration duration: TimeInterval = 1.0) {
        UIView.animate(withDuration: duration, animations: {
            self.alpha = 1.0
        })
    }
}

class ViewController: UIViewController, UINavigationControllerDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
    
    var timer = Timer()
    
    func pulse(imageView: UIImageView, interval: Double) {
        let intv = DispatchTime.now() + interval
        DispatchQueue.main.asyncAfter(deadline: intv) {
            imageView.alpha = 0.5
            imageView.fadeIn()
            self.pulse(imageView: imageView, interval: interval)
        }
    }
    
    var startTime = TimeInterval()
    
    var captureDevice : AVCaptureDevice?
    var session : AVCaptureSession?
    
    var camCovered = false
    var lapsing = false;
    
    let MAX_LUMA_MEAN = Double(100)
    let MIN_LUMA_MEAN = Double(60)
    let MAX_LUMA_STD_DEV = Double(20)
    
    var stateQueue : YChannelStateQueue?
    var heartRates : [Int]?
    var observation : [Int]?

    
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
    @IBOutlet var heartRate: UILabel!
    
    @IBAction func start(sender: AnyObject) {
        if button.currentTitle == "START" {
            heartView.image = UIImage(named: "Heart_normal")
            heartView.alpha = 0.25
            heartView.fadeIn()
            button.setBackgroundImage(UIImage(named: "Button_stop"), for: UIControlState.normal)
            button.setTitle("STOP", for: UIControlState.normal)
            hint1.text = "Waiting for signal."
            hint2.text = "Please cover the camera with your finger."
            startCameraProcesses()
        }
        else {
            heartView.removeFromSuperview()
            displayHeart(imageName: "Heart_inactive")
            
            // End camera processes
            session!.stopRunning()
            toggleFlashlight()
            
            timer.invalidate()
            button.setBackgroundImage(UIImage(named: "Button_start"), for: UIControlState.normal)
            button.setTitle("START", for: UIControlState.normal)
            hint1.text = "Ready to start."
            hint2.text = "Please hit the START button."
            timerText.text = "00:00:00"
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        displayHeart(imageName: "Heart_inactive")

        stateQueue = YChannelStateQueue()
        heartRates = [Int]()
        observation = [Int]()
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
            let aSelector : Selector = #selector(ViewController.updateTime)
            timer = Timer.scheduledTimer(timeInterval: 0.01, target: self, selector: aSelector, userInfo: nil, repeats: true)
            startTime = NSDate.timeIntervalSinceReferenceDate
            pulse(imageView: self.heartView, interval: 1.5)
        }
        else {
            timer.invalidate()
            heartView.removeFromSuperview()
            displayHeart(imageName: "Heart_normal")
            hint1.text = "Waiting for signal."
            hint2.text = "Please cover the camera with your finger."
            timerText.text = "00:00:00"
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
        
        detectFingerCoverage(bytesPerRow: bytesPerRow, byteBuffer: byteBuffer)
        
        if self.camCovered {
            useCaptureOutputForHeartRateEstimation(bytesPerRow: bytesPerRow, byteBuffer: byteBuffer)
        }
        // Compute mean and standard deviation of pixel luma values
        
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
            let sqrdDiff = pow((Double(byteBuffer[index]) - mean), 2)
            sqrdDiffs += sqrdDiff
        }
        let stdDev = sqrt((Double(sqrdDiffs)/Double(pixels)))
        
        return (mean, stdDev);
    }
    
    func detectFingerCoverage(bytesPerRow: Int, byteBuffer: UnsafeMutablePointer<UInt8>) {
        
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
    }
    
    func updateTime() {
        let currentTime = NSDate.timeIntervalSinceReferenceDate
        //Find the difference between current time and start time.
        var elapsedTime: TimeInterval = currentTime - startTime
        //Calculate the minutes in elapsed time.
        let minutes = UInt8(elapsedTime / 60.0)
        elapsedTime -= (TimeInterval(minutes) * 60)
        //Calculate the seconds in elapsed time.
        let seconds = UInt8(elapsedTime)
        elapsedTime -= TimeInterval(seconds)
        //Find out the fraction of milliseconds to be displayed.
        let fraction = UInt8(elapsedTime * 100)
        //Add the leading zero for minutes, seconds and millseconds and store them as string constants
        let strMinutes = String(format: "%02d", minutes)
        let strSeconds = String(format: "%02d", seconds)
        let strFraction = String(format: "%02d", fraction)
        //Concatenate minuets, seconds and milliseconds as assign it to the UILabel
        timerText.text = "\(strMinutes):\(strSeconds):\(strFraction)"
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
                var bestState:Int?
                
                //
                for state2 in states{
                    let transProb = vit[i-1][state2]! * trans[state2][state1]
                    if transProb > transMax{
                        transMax = transProb
                        maxProb = transMax * emit[state1][obs[i]]
                        vit[i][state1] = maxProb
                        bestState = state2
                        newPath[state1] = path[bestState!]! + [state1]
                    }
                }
                
            }
            path = newPath
            
        }
        let len = obs.count - 1
        var bestState:Int?
        var maxProb = DBL_MIN
        for state in states{
            if vit[len][state]! > maxProb{
                maxProb = vit[len][state]!
                bestState = state
            }
        }
        
        
        
        return (maxProb, path[bestState!]!)
        
    }
    
    func calculate(states:Array<Int>)->Int{
        
        var first2 = -1
        var second2 = -1
        var lastSeen2 = false
        var additional2 = false
        for i in 0..<states.count {
            if (states[i] == 2 && first2 == -1) {
                first2 = i
                lastSeen2 = true
            } else if (states[i] == 2 && first2 != -1 && !lastSeen2 && additional2) {
                second2 = i
                //                    self.heartRates!.append(Int(60.0/((Double(second2 - first2 + 1)/90.0)*3.0)))
                DispatchQueue.main.async {
                    self.heartRate!.text = String(describing: Int(60.0/((Double(second2 - first2 + 1)/90.0)*3.0))) + " BPM"
                    additional2 = false
                }
            } else if (states[i] == 2 && first2 != -1 && !lastSeen2 && !additional2) {
                    additional2 = true
//                    print("first2", first2, "second2", second2)
                    first2 = i
                    second2 = -1
                    lastSeen2 = true
                } else if (states[i] != 2) {
                lastSeen2 = false
            }
        }
        
        
        return 0
        
    }
    

    
    func useCaptureOutputForHeartRateEstimation(bytesPerRow: Int, byteBuffer: UnsafeMutablePointer<UInt8>) {
        var sum = 0
        let pixels = 1080 * bytesPerRow
        for index in 0...pixels-1 {
            sum += Int(byteBuffer[index])
        }
        stateQueue?.addValue(value: Double(sum)/Double(pixels))
        
        if (stateQueue?.getState() != -1) {
            observation!.append((stateQueue?.getState())!)
        }
//        print("number of obs", observation!.count)
        if (observation!.count == 90) {
            //            let trans = [[0.6773,0.3227],[0.0842,0.9158]]
            let trans = [[0.6794, 0.3206, 0.0, 0.0],
                         [0.0, 0.5366, 0.4634, 0.0],
                         [0.0, 0.0, 0.3485, 0.6516],
                         [0.1508, 0.0, 0.0, 0.8492]]
            //            let emit = [[0.7689,0.0061,0.1713,0.0537],
            //                        [0.0799,0.6646,0.1136,0.1420]]
            let emit = [[0.6884, 0.0015, 0.3002, 0.0099],
                        [0.0, 0.7205, 0.0102, 0.2694],
                        [0.2894, 0.3731, 0.3362, 0.0023],
                        [0.0005, 0.8440, 0.0021, 0.1534]]
            
            //            let p = [0.2, 0.8]
            let p = [0.25, 0.20, 0.10, 0.45]
            let states = [0,1,2,3]
            
            // 4 obs, increasing, decreasing, local max and local min
//            print(observation!)
//            print(viterbi(obs:observation!, trans:trans, emit:emit, states:states, initial:p))
//            print(calculate(states: viterbi(obs:observation!, trans:trans, emit:emit, states:states, initial:p).1))
//            print(heartRates!)
            //            setLabelText(text: String(calculate(states: viterbi(obs:observation!, trans:trans, emit:emit, states:states, initial:p).1)))
            self.calculate(states: self.viterbi(obs:self.observation!, trans:trans, emit:emit, states:states, initial:p).1)
//            print("Heart rates", self.heartRates!)

            observation!.removeAll()
        }
        
    }
    }




