clear all; close all;

addpath(genpath('/Users/idse/repos/Warmflash/')); 

%dataDir = '/Users/idse/data_tmp/cycloheximide_after_20160330_32055 PM';
%dataDir = '/Users/idse/data_tmp/cycloheximide_before_20160330_42945 PM';

%dataDir = '/Volumes/IdseData/160323_8well_sox17/4days/sox17live_20160327_125754 PM';
%dataDir = '/Volumes/IdseData/160416_RIvsnoRI';
%dataDir = '/Volumes/IdseData/160406-C2C12S4-TGFbRI';
%dataDir = '/Volumes/SeagateBackup/160310_8well_dilutions';
%dataDir = '/Volumes/IdseData/160502_SBbackground';
dataDir = '/Volumes/IdseData/160429_MPRI';

meta = MetadataAndor(dataDir);

nucChannel = 1;
S4Channel = 0;

%%
% visualize positions

meta.displayPositions();

%%

% RERUN CURRENT WITH DBSTOP IF ERROR

% ASSUME: files are split by position & wavelength

channels = [nucChannel S4Channel];

% save idx for channels containing nuclear marker
% saveidx = [true false]; 
saveidx = [true false]; 

inputdir = dataDir;
outputdir = fullfile(dataDir, 'MIP');

batchMIP_Andor(inputdir, outputdir, channels, saveidx);
