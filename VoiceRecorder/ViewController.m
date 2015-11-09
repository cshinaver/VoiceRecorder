//
//  ViewController.m
//  VoiceRecorder
//
//  Created by Spencer King on 9/30/14.
//  Copyright (c) 2014 University of Notre Dame. All rights reserved.
//

//Assistance from:
//http://www.appcoda.com/ios-avfoundation-framework-tutorial/
//http://purplelilgirl.tumblr.com/post/3847126749/tutorial-the-step-two-to-making-a-talking-iphone

#import "ViewController.h"
#import <DropboxSDK/DropboxSDK.h>
#import "ReadingTestViewController.h"

//DBRestClient is used to access Dropbox after linking
@interface ViewController () <DBRestClientDelegate, UIAlertViewDelegate>{
//declare instances for recording and playing
    AVAudioRecorder *recorder;
    AVAudioPlayer *player;
    NSTimer *audioMonitorTimer;

    NSString *fullName;
    NSString *fileName;  // recording file name
    NSString *currentMode; // current recording mode
    NSString *previousMode; // previous recording mode
    NSString *measuresFilePath; // path to battery status file
    NSString *recordingInfoFile; // path to file storing information about recordings
    NSString *comment; // hold the comment text field value untill saved to file
    NSArray *pathComponents;
    NSURL *outputFileURL;
    NSTimer *recordingTimer;
    int numberOfRecordingsForUpload;

    NSURL *monitorTmpFile;
    NSURL *recordedTmpFile;
    AVAudioRecorder *audioMonitor;

    BOOL isRecording;
    BOOL isMonitoring;
    BOOL isPlaying;

    //variables for monitoring the audio input and recording
    double AUDIOMONITOR_THRESHOLD; //don't record if below this number
    double MAX_SILENCETIME; //max time allowed between words
    double MAX_MONITORTIME; //max time to try to record for
    double MAX_RECORDTIME; //max time to try to record for
    double MIN_RECORDTIME; //minimum time to have in a recording
    double silenceTime; //current amount of silence time
    double dt; // Timer (audioMonitor level) update frequencey
    double totalRecordTime; //total records in terms of time
    
    NSArray *tableLables; // array to contain application information
    NSArray *tableData;
    NSArray *_labelPickerData;
    
    NSInteger weekNumber; // current week number to track number of minutes recorded
    double cribTime; // minutes recorded in crib mode within current week
    double supTime; // minutes recorded in supervised mode within current week
    double unsupTime; // minutes recorded in unsupervised mode within current week
    }

@property (nonatomic, strong) DBRestClient *restClient;

@end

@implementation ViewController
@synthesize storageText, currentText, lastRecordingText, recordButton, playButton, uploadButton;

- (void) viewDidLoad {
    [super viewDidLoad];

    //set monitoring and recording variables
    AUDIOMONITOR_THRESHOLD = .1;
    MAX_SILENCETIME = 300.0; // seconds
    MAX_MONITORTIME = 36000.0; // seconds
    MIN_RECORDTIME = 60.0; // seconds
    MAX_RECORDTIME = 3600;  // minutes
    dt = .001;
    silenceTime = 0;

    // Set Bools
    isPlaying = NO;
    isMonitoring = NO;
    isRecording = NO;

    self.restClient = [[DBRestClient alloc] initWithSession:[DBSession sharedSession]];
    self.restClient.delegate = self;
    
     // Disable stop and play buttons in the beginning
    [self.stopButton setEnabled:NO];
    [self.playButton setEnabled:NO];
    
    // Set number of recordings remaining
    [self setNumberOfFilesRemainingForUpload];
    

    // Get user info
    [self getUsername];
    if (!fullName)
    {
        [self askForUserInfo];
    }
    
    self.labelUsername.text = [NSString stringWithFormat:@"User: %@", fullName];
    

    // Set disk space etc
    [self setFreeDiskspace];
    
    //set user specific settings
    [self setUserSpecificSettings];
    
    //setup mode buttons
    [self initRecordingModeButtons];

    // uncomment if you want to record battery status
    //[self recordBatteryStatus];
    
    //set week number for the first time
    if([self getWeekOfYear] == 0){
        NSCalendar *cal = [NSCalendar currentCalendar];
        NSDateComponents *components = [cal components:NSCalendarUnitWeekOfYear fromDate:[NSDate date]];
        weekNumber = [components weekOfYear];
        [self saveWeekOfYear:weekNumber];
    }
    
    
    
    [self.textfieldComment setDelegate:self];
    
    //load recording time for each mode
    [self loadRecordedTime];
    
    
    
}


//set up the filename
-(void)setOutputFileUrl {

    // If name not set, set name
    if (!fullName)
    {
        [self askForUserInfo];
    }

    //name the file with the recording date, later add device ID
    fileName = [NSString stringWithFormat:@"Recording of %@ %@ %@.m4a", self->fullName, self->currentMode, [self getDate]];

    //set the audio file
    //this is for defining the URL of where the sound file will be saved on the device
    // Currently saving files to Documents directory. Might be better to save to tmp
    pathComponents = [NSArray arrayWithObjects:
        [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) lastObject],
        fileName,
                      
        nil];

    outputFileURL = [NSURL fileURLWithPathComponents:pathComponents];
}

//uploads the file
-(IBAction)uploadFiles {
    /*
     * Iterates through documents directory, searches for files beginning with
     * "Recording", and uploads files.
     */

    // Dropbox destination path
    NSString *destDir = @"/";

    // Get file manager
    NSFileManager *fileManager = [NSFileManager defaultManager];
    // Get directory path
    NSString *documentsDir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];

    NSArray *dirContents = [fileManager contentsOfDirectoryAtPath:documentsDir error:nil];

    // Iterate through contents, if starts with "Recording", upload
    NSString *filePath;

    for (filePath in dirContents)
    {
        if ([filePath containsString:@"Recording"] || [filePath containsString:@"ReadingTest"])
        {
            NSLog(@"filePath: %@", filePath);

            NSString *localPath = [documentsDir stringByAppendingPathComponent:filePath];
            // Upload file to Dropbox
            [self.restClient uploadFile:filePath toPath:destDir withParentRev:nil fromPath:localPath];
        }
        
//        if ([filePath containsString:@"ReadingTest"])
//        {
//            NSLog(@"filePath: %@", filePath);
//            
//            NSString *localPath = [documentsDir stringByAppendingPathComponent:filePath];
//            // Upload file to Dropbox
//            [self.restClient uploadFile:filePath toPath:destDir withParentRev:nil fromPath:localPath];
//        }

    }
    
    if(recordingInfoFile != NULL){
    
    [self.restClient uploadFile:[NSString stringWithFormat:@"comments/%@-info.csv",fullName] toPath:destDir fromPath:recordingInfoFile];
    }

}

//initialize the audio monitor
-(void) initAudioMonitorAndRecord{

    // Set session to play and record
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayAndRecord error:nil];

    NSMutableDictionary* recordSetting = [[NSMutableDictionary alloc] init];
    [recordSetting setValue :[NSNumber numberWithInt:kAudioFormatAppleIMA4] forKey:AVFormatIDKey];
    [recordSetting setValue:[NSNumber numberWithFloat:44100.0] forKey:AVSampleRateKey];
    [recordSetting setValue:[NSNumber numberWithInt: 1] forKey:AVNumberOfChannelsKey];

    NSArray* documentPaths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString* fullFilePath = [[documentPaths objectAtIndex:0] stringByAppendingPathComponent: @"monitor.caf"];
    monitorTmpFile = [NSURL fileURLWithPath:fullFilePath];

    audioMonitor = [[ AVAudioRecorder alloc] initWithURL: monitorTmpFile settings:recordSetting error:NULL];

    [audioMonitor setMeteringEnabled:YES];

    [audioMonitor setDelegate:self];

    [audioMonitor record];
    isMonitoring = YES;

    // Timer for update of audio level
    audioMonitorTimer = [NSTimer scheduledTimerWithTimeInterval:dt target:self selector:@selector(monitorAudioController) userInfo:nil repeats:YES];
    
    // Timer for update of time elapsed label
    recordingTimer = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(updateSlider) userInfo:nil repeats:YES];  //this is nstimer to initiate update method
}

//initialize the recorder
-(void) initRecorder{
    /*
       Initializes the recorder and recorder settings
       */


    //set up the audio session
    //this allows for both playing and recording
    //CHANGE THIS LATER ONCE IT WORKS, ONLY NEED RECORDING
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayAndRecord error:nil];

    //define the recorder settings
    //the AVAudioRecorder uses dictionary-based settings
    NSMutableDictionary *recordSetting = [[NSMutableDictionary alloc] init];

    [recordSetting setValue:[NSNumber numberWithInt:kAudioFormatMPEG4AAC] forKey:AVFormatIDKey];
    [recordSetting setValue:[NSNumber numberWithFloat:44100.0] forKey:AVSampleRateKey];
    [recordSetting setValue:[NSNumber numberWithInt: 2] forKey:AVNumberOfChannelsKey];

    //initiate and prepare the recorder
    recorder = [[AVAudioRecorder alloc] initWithURL:outputFileURL settings:recordSetting error:NULL];
    recorder.delegate = self;
    recorder.meteringEnabled = YES;
    [recorder prepareToRecord]; //this line initiates the recorder

}


-(void) monitorAudioController
{
    /*
     * Meant to be called on a timer, this gets the audio level from the
     * audioMonitor and converts it to a zero to 1 scale. If the audio level is
     * greater than the AUDIOMONITOR_THRESHOLD value, if the recorder is not
     * recording, it begins recording and isRecording is set to YES. If the
     * audio level is not above the AUDIOMONITOR_THRESHOLD value, the recorder
     * stops recording
     */

    static double audioMonitorResults = 0;
    // TODO Check if isPlaying is neccessary 
    if(!isPlaying)
    {   
        [audioMonitor updateMeters];

        // a convenience, it’s converted to a 0-1 scale, where zero is complete quiet and one is full volume
        const double ALPHA = 0.05;
        double peakPowerForChannel = pow(10, (0.05 * [audioMonitor peakPowerForChannel:0]));
        audioMonitorResults = ALPHA * peakPowerForChannel + (1.0 - ALPHA) * audioMonitorResults;

        self.audioLevelLabel.text = [NSString stringWithFormat:@"Level: %f", audioMonitorResults];

        //####################### RECORDER AUDIO CHECKING #####################
        // set status label
        if (isRecording)
        {
            self.statusLabel.text = @"Recording.";
        }
        else
        {
            self.statusLabel.text = @"Not recording.";
        }
        //check if sound input is above the threshold
        if (audioMonitorResults > AUDIOMONITOR_THRESHOLD)
        {   
            self.statusLabel.text = [self.statusLabel.text stringByAppendingString:@" Sound detected."];
            if(!isRecording)
            {
                // start recording
                [self startRecording];
            }
        }
        //not above threshold, so don't record
        else{
            self.statusLabel.text = [self.statusLabel.text stringByAppendingString:@" Silence detected"];
            if(isRecording){
                // if we're recording and above max silence time
                if(silenceTime > MAX_SILENCETIME){
                    // stop recording
                    [self stopRecorder];
                    silenceTime = 0;
                }
                else{
                    //silent but hasn't been silent for too long so increment time
                    // For some reason, increment is off by 10
                    silenceTime += dt;
                }
            }
        }
        //##################################################################### 


        //####################### MONITOR CHECKING ###########################
        // If monitor time greater than max allowed monitor time, stop monitor
        if([audioMonitor currentTime] > MAX_MONITORTIME){
            [self stopAudioMonitorAndAudioMonitorTimer];
        }
        //####################################################################

    }

}

-(void) startRecorder{
    /*
     * Sets recorder to start recording and sets isRecording to YES
     */

    NSLog(@"startRecorder");

    isRecording = YES;
    //[self setLastRecordingText]; //set the last recording time
    [recorder record];
}

//stop the recording and play it
-(void) stopRecorderAndPlay{

    NSLog(@"stopRecorder Record time: %f", [recorder currentTime]);

    if([recorder currentTime] > MIN_RECORDTIME)
    {   isRecording = NO;
        [recorder stop];

        isPlaying = YES;
        // insert code for playing the audio here
        player = [[AVAudioPlayer alloc] initWithContentsOfURL:recorder.url error:nil];
        [player setDelegate:self];
        [player play];
        isPlaying = NO;
        //[self monitorAudioController];
        NSLog(@"playing");
    }
    else{
        [audioMonitor record];
    }
    //[audioMonitor record];
    //[NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(monitorAudioController) userInfo:nil repeats:YES];
    //NSLog(@"calling again");
}

-(void) stopRecorder{
    /*
     * Stops the recorder and sets isRecording to NO. Displays about of time
     * recorded
     */

    // Log elapsed record time
    double timeRecorded = [recorder currentTime];
    NSLog(@"stopRecorder Record time: %f", timeRecorded);
    totalRecordTime += timeRecorded;
    float minutesRecorded = floor(totalRecordTime/60);
    float secondsRecorded = totalRecordTime - (minutesRecorded * 60);

    
    self.numberOfMinutesRecorded.text = [[NSString alloc] initWithFormat:@"%0.0f:%0.0f", minutesRecorded, secondsRecorded];
    
    [self updateRecordingTime:previousMode :timeRecorded];

    // TODO Check if MIN_RECORDTIME is necessary considering there is a
    // MAX_SILENCETIME
    isRecording = NO;
    [recorder stop];
    
    //update metadata file
    [self updateMetadataFile];
}

//stop playing
-(void) stopPlaying{
    isPlaying = NO;
    [audioMonitor record];
}

-(void) stopAndRecord{
    [self stopRecorder];
    [self stopAudioMonitorAndAudioMonitorTimer];
    [recordingTimer invalidate];
    
    // Update count of recordings
    [self setNumberOfFilesRemainingForUpload];
    
    // Update display of the free space on the device
    [self setFreeDiskspace];

    
    //hide time
    [self.timeElapsedLabel setHidden:YES];

    [self startRecording];
}

//displays the last time a recording was made
-(void) setLastRecordingText{

    NSString* last;
    NSString* date;
    last = @"Last recording date: ";
    date = [self getDate];
    NSString* str = [NSString stringWithFormat: @"%@ %@", last, date]; //concatenate the strings
    lastRecordingText.text = str;

    [self saveToUserDefaults:str];
}

//saves the last recording date to the user defaults
-(void)saveToUserDefaults:(NSString*)recordingDate
{
    NSUserDefaults *standardUserDefaults = [NSUserDefaults standardUserDefaults];

    if (standardUserDefaults) {
        [standardUserDefaults setObject:recordingDate forKey:@"lastRecordingDate"];
        [standardUserDefaults synchronize];
    }
}

//https://developer.apple.com/library/ios/documentation/cocoa/Conceptual/DataFormatting/Articles/dfDateFormatting10_4.html
//this function returns the date, which will be used for the recording file name
- (NSString*)getDate {
    //initialize variables
    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    NSString        *dateString;

    [dateFormatter setDateFormat:@"dd-MM-yyyy HH:mm:ss"]; //format the date string

    dateString = [dateFormatter stringFromDate:[NSDate date]]; //get the date string

    return dateString; //return the string
}

//http://stackoverflow.com/questions/5712527/how-to-detect-total-available-free-disk-space-on-the-iphone-ipad-device
- (void)setFreeDiskspace
{
    /*
     * Calculates free disk space and sets Label
     */

    //uint64 gives better precision
    uint64_t totalSpace = 0;
    uint64_t totalFreeSpace = 0;

    __autoreleasing NSError *error = nil;
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSDictionary *dictionary = [[NSFileManager defaultManager] attributesOfFileSystemForPath:[paths lastObject] error: &error];

    if (dictionary) {
        NSNumber *fileSystemSizeInBytes = [dictionary objectForKey: NSFileSystemSize];
        NSNumber *freeFileSystemSizeInBytes = [dictionary objectForKey:NSFileSystemFreeSize];

        //get total space and free space
        totalSpace = [fileSystemSizeInBytes unsignedLongLongValue];
        totalFreeSpace = [freeFileSystemSizeInBytes unsignedLongLongValue];

        //print free space to console as a check
        //NSLog(@"Memory Capacity of %llu MiB with %llu MiB Free memory available.", ((totalSpace/1024ll)/1024ll), ((totalFreeSpace/1024ll)/1024ll));
    } else {
        //print an error to the console if not able to get memory
        NSLog(@"Error Obtaining System Memory Info: Domain = %@, Code = %ld", [error domain], (long)[error code]);
    }


    //Make and display a string of the current free space of the device
    //If we want to display minutes remaining, recordings take roughly 2MB/minute

    uint64_t actualFreeSpace = totalFreeSpace/(1024*1024); //convert to megabytes
    uint64_t freeSpaceMinutes = actualFreeSpace/2; //convert to minutes
    NSString* space = [@(actualFreeSpace) stringValue]; //put free space into a string
    NSString* spaceUnit = @" MB"; //string for the unit of free space

    // Remaining memory percentage, amount of minutes remaining,
    uint64_t percentageSpaceRemaining = (totalFreeSpace * 100/totalSpace);
    self.percentageDiskSpaceRemainingLabel.text = [NSString stringWithFormat:@"%llu%%", percentageSpaceRemaining];
    
    float minutesRecorded = floor(totalRecordTime/60);
    float secondsRecorded = totalRecordTime - (minutesRecorded * 60);
    self.numberOfMinutesRecorded.text = [[NSString alloc] initWithFormat:@"%0.0f:%0.0f", minutesRecorded, secondsRecorded];
}


//BUTTONS
- (IBAction)trackProgressTapped:(id)sender {
    [self showProgress];
}

//record button tapped
- (IBAction)recordTapped:(id)sender {
     /*
     * When record button is tapped, Audio monitor should be started
     */
    [self startRecording];
   
}

//comment added
- (IBAction)commentEndEditing:(id)sender {
    
    comment = self.textfieldComment.text;

}

-(void)startRecording{

    if (!isMonitoring)
    {
        AVAudioSession *session = [AVAudioSession sharedInstance];
        [session setActive:YES error:nil];
        
        [self initAudioMonitorAndRecord];
        
        // Start monitoring
        // Disable record button
        [self.recordButton setEnabled:NO];
    }
    
    // Recorder needs to be initialized each time due to the file url
    // property being readonly. New file url must be set for each recording
    // Setup audio file
    [self setOutputFileUrl];
    
    // Setup Audio Session and Recorder
    [self initRecorder];
    
         NSLog(@"%@",outputFileURL);
    // Start recording
    [recorder record];
    isRecording = YES;
    
    // Enable stop button and disable play button
    [self.stopButton setEnabled:YES];
    [self.playButton setEnabled:NO];
    
    
    //show time
    self.timeElapsedLabel.text = @"Time 0:0";
    [self.timeElapsedLabel setHidden:NO];
    
}

-(void)startNewRecording
{
    /*
     * Starts new recording by getting audio session, setting it active,
     * setting outputFileUrl, initializing the recorder, starting the recorder,
     * and starting a recordingTimer that updates the elapsed time label
     */

    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setActive:YES error:nil];

    // Recorder needs to be initialized each time due to the file url
    // property being readonly. New file url must be set for each recording
    // Setup audio file
    [self setOutputFileUrl];

    // Setup Audio Session and Recorder
    [self initRecorder];

    // Start recording
    [recorder record];
    isRecording = YES;


    // Set buttons
    [self.recordButton setEnabled:NO];
    [self.stopButton setEnabled:YES];
    [self.playButton setEnabled:NO];

}

- (void)updateSlider {
    // Update the slider about the music time
    float minutesMonitoring = floor(audioMonitor.currentTime/60);
    float secondsMonitoring = audioMonitor.currentTime - (minutesMonitoring * 60);

    float minutesRecording = floor(recorder.currentTime/60);
    float secondsRecording = recorder.currentTime - (minutesRecording * 60);

    //uncomment for the original-commented just for texting
   NSString *time = [[NSString alloc] initWithFormat:@"Time %0.0f:%0.0f", minutesMonitoring, secondsMonitoring];
    
    //comment after testing
  //  NSString *time = [[NSString alloc] initWithFormat:@"Time %0.0f:%0.0f", minutesRecording, secondsRecording];
    
    self.timeElapsedLabel.text = time;

    // If recording has gone on for more than given time, start new recording
    // In minutes
    double allowedElapsedTime = MAX_RECORDTIME;
    if (minutesRecording >= allowedElapsedTime && isRecording)
    {
        // Stop old recording and start new one to decrease upload file sizes
        [self stopRecorder];
        [self startNewRecording];
        [self setNumberOfFilesRemainingForUpload];
    }
}

//stops the recorder and deactivates the audio session
- (IBAction)stopTapped:(id)sender {

    previousMode = currentMode;
    [self stopRecorder];
    [self stopAudioMonitorAndAudioMonitorTimer];
    [recordingTimer invalidate];

    // Update count of recordings
    [self setNumberOfFilesRemainingForUpload];

    // Update display of the free space on the device
    [self setFreeDiskspace];

    //reset buttons
    [self resetModeButtons];
     currentMode = @"";
    
    //hide time
    [self.timeElapsedLabel setHidden:YES];

}

- (void)stopAudioMonitorAndAudioMonitorTimer
{
    /*
     * Stops audioMonitor and audioMonitorController selector (on a timer)
     */

    [audioMonitor stop];
    [audioMonitorTimer invalidate];
    isMonitoring = NO;
    NSLog(@"Audio Monitor stopped");

    // Give up audio session
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setActive:NO error:nil];
}

//makes sure no recording or monitoring is happening and then plays
- (IBAction)playTapped:(id)sender {
    /*
     * Plays back most recent recording
     */

    if (!recorder.recording)
    {
        player = [[AVAudioPlayer alloc] initWithContentsOfURL:recorder.url error:nil];
        player.delegate = self;
        [player play];
    };
}

// Show alert after recording
- (void) audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag{
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle: @"Done" message: @"Finish playing the recording!" delegate: nil cancelButtonTitle:@"OK" otherButtonTitles:nil];
    [alert show];
}

//for linking to dropbox
// TODO: Just put this to upload button
- (IBAction)uploadFile:(id)sender
{
    if (![[DBSession sharedSession] isLinked]) {
        [[DBSession sharedSession] linkFromController:self];
        NSLog(@"linking");
    }
    NSLog(@"already linked");
    
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Upload Started.." message:nil delegate:self cancelButtonTitle:nil otherButtonTitles: nil];
    [alert show];
    [self.uploadButton setEnabled:NO];
    
    UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
    

    indicator.center = CGPointMake(alert.bounds.size.width / 2, alert.bounds.size.height - 50);
    [indicator startAnimating];
    [alert addSubview:indicator];
    [alert dismissWithClickedButtonIndex:0 animated:YES];
    [self uploadFiles]; //upload the test file
    [self.uploadButton setEnabled:YES];
}



- (void)restClient:(DBRestClient *)client uploadedFile:(NSString *)destPath
              from:(NSString *)srcPath metadata:(DBMetadata *)metadata {

                  NSFileManager *fileManager = [NSFileManager defaultManager];
                  NSLog(@"File uploaded successfully to path: %@ from path: %@", metadata.path, srcPath);

                  // Delete file after upload
                  //dont delete the <name>-info.csv file
                  NSError *error;
    
                if(srcPath != recordingInfoFile){
                  BOOL success = [fileManager removeItemAtPath:srcPath error:&error];
                  // Display success message if all recordings successfully uploaded
                    // Update count of recordings
                    [self setNumberOfFilesRemainingForUpload];
                    
                  // numberOfRecordingsForUpload=1 because we are checking before deleting the file
                  if (success && numberOfRecordingsForUpload == 0) {

                      UIAlertView *alert = [[UIAlertView alloc] initWithTitle: @"Upload Success" message: @"All Files uploaded successfully!" delegate: nil cancelButtonTitle:@"OK" otherButtonTitles:nil];
                      [alert show];

                  }
                  else if(!success){
                      NSString *errorText = [@"Could not delete file -:" stringByAppendingString:[error localizedDescription]];
                      
                      UIAlertView *alert = [[UIAlertView alloc] initWithTitle: @"Upload Failed" message:errorText delegate: nil cancelButtonTitle:@"OK" otherButtonTitles:nil];
                      [alert show];
                  }
                  else
                  {
                      

                      NSLog(@"Could not delete file -:%@ ",[error localizedDescription]);
                  }


                }

              }

- (void)restClient:(DBRestClient *)client uploadFileFailedWithError:(NSError *)error {

    NSString *errorText = [error localizedDescription];
    
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle: @"Upload Failed" message:errorText delegate: nil cancelButtonTitle:@"OK" otherButtonTitles:nil];
    [alert show];
    
    [self.restClient cancelAllRequests];
    
    NSLog(@"File upload failed with error: %@", error.localizedDescription);
}

- (void)setNumberOfFilesRemainingForUpload {
    /*
     * Calculates and sets Label of number of files remaining for uplaod
     */
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = [paths objectAtIndex:0];
    NSArray *filePathsArray = [[NSFileManager defaultManager] subpathsOfDirectoryAtPath:documentsDirectory error:nil];
    NSString *filePath;
    int numOfRecordings = 0;
    for (filePath in filePathsArray)
    {
        if ([filePath containsString:@"Recording"] || [filePath containsString:@"ReadingTest"])
        {
            numOfRecordings++;
        }
    }

    self->numberOfRecordingsForUpload = numOfRecordings;
    self.numberOfRecordingsForUploadLabel.text = [NSString stringWithFormat:@"%i", numOfRecordings];
}

- (void)askForUserInfo
{
    /*
     * Opens alert box asking user for information
     * if first name @"admin" and last @"", development button will be shown
     */
    UIAlertView *alert=[[UIAlertView alloc]initWithTitle:@"Full name" message:@"Please enter your full name" delegate:nil cancelButtonTitle:@"Cancel" otherButtonTitles:@"OK", nil];
    alert.alertViewStyle=UIAlertViewStylePlainTextInput;
    [alert setDelegate:self];
    [alert show];
   
}

-(void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex{
    self->fullName = [alertView textFieldAtIndex:0].text;
    [self saveUsername:fullName];
    self.labelUsername.text = [NSString stringWithFormat:@"User: %@", fullName];
    if (fileName == nil) {
        [self initInfoFile]; // load file to record recording metadata
    }
}

-(void)addItemViewController:(DevelopmentInterfaceViewController *)controller passDevelopmentSettings:(DevelopmentSettings *)developmentSettings
{
    [self setDevelopmentSettingsFromInput:developmentSettings];
}

#pragma mark - Navigation

// In a storyboard-based application, you will often want to do a little preparation before navigation
- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
    // Get the new view controller using [segue destinationViewController].
    // Pass the selected object to the new view controller.
    DevelopmentSettings *settings = [DevelopmentSettings new];
    settings.AUDIOMONITOR_THRESHOLD = AUDIOMONITOR_THRESHOLD;
    settings.MAX_SILENCETIME = MAX_SILENCETIME;
    settings.MAX_MONITORTIME = MAX_MONITORTIME;
    settings.MAX_RECORDTIME = MAX_RECORDTIME;
    settings.MIN_RECORDTIME = MIN_RECORDTIME;
    settings.silenceTime = silenceTime;
    settings.dt = dt;

    DevelopmentInterfaceViewController *dvc = [segue destinationViewController];
    dvc.settings = settings;
    dvc.delegate = self;
    
  
    
}

- (void)setDevelopmentSettingsFromInput: (DevelopmentSettings *)settings
{
    AUDIOMONITOR_THRESHOLD  = settings.AUDIOMONITOR_THRESHOLD;
    MAX_SILENCETIME  = settings.MAX_SILENCETIME;
    MAX_MONITORTIME  = settings.MAX_MONITORTIME;
    MAX_RECORDTIME  = settings.MAX_RECORDTIME;
    MIN_RECORDTIME  = settings.MIN_RECORDTIME;
    silenceTime  = settings.silenceTime;
    dt  = settings.dt;
}

// save user name
- (IBAction)saveUsername:(NSString*)username {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setValue:username forKey:@"username"];
    [defaults synchronize];
}

- (IBAction)getUsername{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    fullName = [defaults objectForKey:@"username"];
}

-(void)loadRecordedTime{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    cribTime = [defaults floatForKey:@"cribTime"];
    supTime = [defaults floatForKey:@"supTime"];
    unsupTime = [defaults floatForKey:@"unsupTime"];
}

-(void)saveRecordedTime{
    NSUserDefaults *defaults =[NSUserDefaults standardUserDefaults];
    [defaults setFloat:cribTime forKey:@"cribTime"];
    [defaults setFloat:supTime forKey:@"supTime"];
    [defaults setFloat:unsupTime forKey:@"unsupTime"];
    [defaults synchronize];
}


- (NSInteger)getWeekOfYear{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    weekNumber = (NSInteger)[defaults objectForKey:@"weekOfYear"];
    return weekNumber;
}

-(void) saveWeekOfYear:(NSInteger)weekOfYear{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setInteger:weekOfYear forKey:@"week"];
    [defaults synchronize];
}

//set user specific settings

-(void)setUserSpecificSettings{
    
    //disable advanced settings if the username is not admin
    if([fullName  isEqual: @"admin"]){
        [self.statusLabel setHidden:YES];
        [self.audioLevelLabel setHidden:NO];
        [self.playButton setHidden:NO];
        //TODO hide advanced settings
    }else{
        [self.statusLabel setHidden:YES];
        [self.audioLevelLabel setHidden:YES];
        [self.playButton setHidden:YES];
    }
    

}


-(void) initRecordingModeButtons{
    
    [self.buttonCribOn setTag:0];
    [self.buttonSupOn setTag:1];
    [self.buttonUnsupOn setTag:2];
    [self.buttonCribOn  addTarget:self action:@selector(modeChanged:) forControlEvents:UIControlEventTouchUpInside];
    [self.buttonSupOn  addTarget:self action:@selector(modeChanged:) forControlEvents:UIControlEventTouchUpInside];
    [self.buttonUnsupOn  addTarget:self action:@selector(modeChanged:) forControlEvents:UIControlEventTouchUpInside];
    
    [self.buttonCribOff addTarget:self action:@selector(stopTapped:) forControlEvents:UIControlEventTouchUpInside];
}


-(void)resetModeButtons{
    
    [self.buttonCribOn setEnabled:YES];
    [self.buttonCribOff setEnabled:NO];
    [self.buttonSupOn setEnabled:YES];
    [self.buttonUnsupOn setEnabled:YES];
    [self.buttonCribOn setSelected:NO];
    [self.buttonSupOn setSelected:NO];
    [self.buttonUnsupOn setSelected:NO];
    
    //clear comment field
    self.textfieldComment.text =@"";
}

-(void)modeChanged:(id)sender{
    previousMode = currentMode;
    [self resetModeButtons];
    switch ([sender tag]) {
        case 0:
            currentMode = @"CRIB";
            [self.buttonCribOn setSelected:YES];
            [self.buttonCribOff setEnabled:YES];
            [self.buttonSupOn setSelected:NO];
            [self.buttonUnsupOn setSelected:NO];
            break;
        case 1:
            currentMode = @"SUPERVISED";
            [self.buttonCribOn setSelected:NO];
            [self.buttonCribOff setEnabled:YES];
            [self.buttonSupOn setSelected:YES];
            [self.buttonUnsupOn setSelected:NO];
            break;
        case 2:
            currentMode = @"UNSUPERVISED";
            [self.buttonCribOn setSelected:NO];
            [self.buttonCribOff setEnabled:YES];
            [self.buttonSupOn setSelected:NO];
            [self.buttonUnsupOn setSelected:YES];
            break;
        default:
            break;
    }
    
    //initially previous mode is null
    
    if(previousMode == nil || [previousMode isEqualToString:@""]){
        previousMode = currentMode;
    }
    
    
    /*
     * When record button is tapped, Audio monitor should be started
     */
    
    if (!isMonitoring)
    {
        AVAudioSession *session = [AVAudioSession sharedInstance];
        [session setActive:YES error:nil];
        
        [self initAudioMonitorAndRecord];
        
    }
    else{
        [self stopAndRecord];
    }
    
    // Enable stop button and disable play button
    [self.buttonCribOff setEnabled:YES];
    
    //show time
    self.timeElapsedLabel.text = @"Time 0:0";
    [self.timeElapsedLabel setHidden:NO];
     NSLog(@"%@",outputFileURL);
    
}


//methods to check battery status. These are used to compare microphones.

-(void)recordBatteryStatus{
    
    [[UIDevice currentDevice] setBatteryMonitoringEnabled:YES];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(batteryLevelChanged:)
                                                 name:UIDeviceBatteryLevelDidChangeNotification object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(batteryStateChanged:)
                                                 name:UIDeviceBatteryStateDidChangeNotification object:nil];
    
    if(measuresFilePath == nil) {
        NSString *documentsDir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];

        NSString *fileName = [NSString stringWithFormat:@"batterylevel.csv"];
        NSString *filePath = [documentsDir stringByAppendingPathComponent:fileName];
        measuresFilePath = filePath;
        NSError *error = nil;
        BOOL success = [@"" writeToFile:filePath atomically:YES encoding:NSUTF8StringEncoding error:&error];
        if(success == NO) {
            NSLog(@"-- cannot create measures files %@", error);
            return;
        }
        
    }

}


- (void)updateBatteryState
{
       UIDeviceBatteryState currentState = [UIDevice currentDevice].batteryState;
    float batteryLevel = [UIDevice currentDevice].batteryLevel;
    
    NSString *deviceInfo=[NSString stringWithFormat:@"time:, %d, monitor-time:, %f, record:, %f ,deviceBatteryState:, %ld, deviceBatteryLevel:, %f",  (int)[[NSDate date] timeIntervalSince1970], [audioMonitor currentTime], [recorder currentTime], (long)currentState, batteryLevel];
    
    NSString *csvLine = [deviceInfo stringByAppendingString:@"\n"];
    NSData *csvData = [csvLine dataUsingEncoding:NSUTF8StringEncoding];
    NSFileHandle *fh = [NSFileHandle fileHandleForUpdatingAtPath:measuresFilePath];
    [fh seekToEndOfFile];
    [fh writeData:csvData];
    [fh closeFile];
    
}

- (void)batteryLevelChanged:(NSNotification *)notification
{
    [self updateBatteryState];
}

- (void)batteryStateChanged:(NSNotification *)notification
{
    [self updateBatteryState];
}


//track amount of recordings done for the week
-(void) updateRecordingTime:(NSString*)recordingMode : (double)duration
{
    //Get current week number
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDateComponents *components = [cal components:NSCalendarUnitWeekOfYear fromDate:[NSDate date]];
    NSInteger currentWeek = [components weekOfYear];
    NSLog(@"Week nummer: %d", (int)currentWeek);
    
    if (weekNumber == (int)currentWeek + 1 ){
        //start of next week. reset times
        cribTime = 0;
        supTime  = 0;
        unsupTime = 0;
        weekNumber = currentWeek;
        [self saveWeekOfYear:weekNumber];
    }
    
    
    if (weekNumber == currentWeek ){
        
        if ( [recordingMode  isEqual: @"CRIB"]){
            cribTime += duration;
        }
        else if ( [recordingMode  isEqual: @"SUPERVISED"]){
            supTime += duration;
        }else if ( [recordingMode  isEqual: @"UNSUPERVISED"]){
            unsupTime += duration;
        }
    }
    
    //save to user defaults to make persistant
    [self saveRecordedTime];
    
    NSLog(@"crib: %f, sup: %f, unsup: %f ", cribTime, supTime, unsupTime);
}


//show the amount of recordings done within the current week
-(void)showProgress{
    
    NSMutableString *message = [NSMutableString string];
    
    int hours, mins;
    float seconds;
    
    //calculate total crib mode recording time
    
    hours = floor(cribTime/3600);
    mins  = floor((cribTime - hours*3600)/60);
    seconds = cribTime - hours*3600 - mins*60;
    
    [message appendString: [[NSString alloc] initWithFormat:@"CRIB Mode\t\t\t\t %d:%d:%0.0f\n", hours, mins, seconds ]];
    
    
    //calculate supervised mode time
    
    hours = floor(supTime/3600);
    mins  = floor((supTime - hours*3600)/60);
    seconds = supTime - hours*3600 - mins*60;
    
    [message appendString: [[NSString alloc] initWithFormat:@"SUPERVISED Mode\t\t %d:%d:%0.0f\n", hours, mins, seconds ]];
    
    //calculate un-supervised mode time
    
    hours = floor(unsupTime/3600);
    mins  = floor((unsupTime - hours*3600)/60);
    seconds = unsupTime - hours*3600 - mins*60;
    
    [message appendString: [[NSString alloc] initWithFormat:@"UN-SUPERVISED Mode\t %d:%d:%0.0f     \n", hours, mins, seconds ]];
    
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle: @"Hours Recorded During the Week" message:message delegate: nil cancelButtonTitle:@"OK" otherButtonTitles:nil];
    
    
    
    [alert show];
    
}


-(void)initInfoFile{
    
    if(recordingInfoFile == nil) {
        NSString *documentsDir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
        
        NSString *infoFileName = [NSString stringWithFormat:@"%@-info.csv",fullName];
        NSString *filePath = [documentsDir stringByAppendingPathComponent:infoFileName];
        recordingInfoFile = filePath;
        
        if (![[NSFileManager defaultManager] fileExistsAtPath:recordingInfoFile]) {
            [[NSFileManager defaultManager] createFileAtPath:recordingInfoFile contents:nil attributes:nil];
        }
    }
}

-(void)updateMetadataFile{
    
    if (fileName == nil) {
     [self initInfoFile]; // load file to record recording metadata
    }
 
    NSDate *today = [NSDate date];
    NSDateFormatter *dateFormat = [[NSDateFormatter alloc] init];
    [dateFormat setDateFormat:@"dd/MM/yyyy"];
    
    
    NSString *info=[NSString stringWithFormat:@"Date:, %@, Mode:, %@, File:, %@, Comments:, %@, Duration:, %f",
                                                    [dateFormat stringFromDate:today],
                                                    previousMode,
                                                    fileName,
                                                    comment,
                                                    totalRecordTime];
    
    //clear the comment variable after saving
    comment = nil;
    
    NSString *csvLine = [info stringByAppendingString:@"\n"];
    NSData *csvData = [csvLine dataUsingEncoding:NSUTF8StringEncoding];
    NSFileHandle *fh = [NSFileHandle fileHandleForUpdatingAtPath:recordingInfoFile];
    [fh seekToEndOfFile];
    [fh writeData:csvData];
    [fh closeFile];
  
    
}
- (IBAction)readingTestTapped:(id)sender {
    ReadingTestViewController *readingTestView= (ReadingTestViewController *)[[ReadingTestViewController alloc] initWithNibName:nil bundle:nil];
//    ReadingTestViewController *readingTestView = (ReadingTestViewController *)[storyboard instantiateViewControllerWithIdentifier:(NSString *)@"secondBoard"];

    readingTestView.modalTransitionStyle=UIModalTransitionStyleFlipHorizontal;
    [self presentModalViewController:readingTestView animated:YES];

}

-(BOOL)textFieldShouldReturn:(UITextField *)textField
{
    [self.textfieldComment resignFirstResponder];
    return YES;
}


@end
