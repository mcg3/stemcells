clear all; close all;

addpath(genpath('/Users/idse/repos/Warmflash/')); 
warning('off', 'MATLAB:imagesci:tiffmexutils:libtiffWarning');

%dataDir = '/Volumes/IdseData/160318_micropattern_lefty/lefty';
dataDir = '/Volumes/IdseData/160318_micropattern_lefty/control';

%btfname = fullfile(dataDir, '160319_lefty.btf');
btfname = fullfile(dataDir, '160318_control.btf');

%vsifile = fullfile(dataDir,'Image665.vsi');

metaDataFile = fullfile(dataDir,'metaData.mat');

% size limit of data chunks read in
maxMemoryGB = 4;

%% metadata

% read metadata
if exist(metaDataFile,'file')
    disp('loading previously stored metadata');
    load(metaDataFile);
elseif exist('vsifile','var') && exist(vsifile,'file')
    disp('extracting metadata from vsi file');
    meta = readMeta_OlympusVSI(vsifile);
    
% or pretty much enter it by hand
else
    meta = struct();
    h = Tiff(btfname);
    meta.ySize = h.getTag('ImageLength');
    meta.xSize = h.getTag('ImageWidth');
    h.close;
    meta.nChannels = 4;
    meta.channelNames = {'DAPI','GFP','RFP','CY5'};
    meta.xres = 0.650/2;
    meta.yres = meta.xres;
end

% manually entered metadata
%------------------------------

meta.colRadiiMicron = [200 500 800 1000]/2;
meta.colMargin = 10; % margin outside colony to process
meta.antibodyNames = {'DAPI','Cdx2','Sox2','Bra'};

meta.colRadiiPixel = meta.colRadiiMicron/meta.xres;
DAPIChannel = find(strcmp(meta.channelNames,'DAPI'));

save(fullfile(dataDir,'metaData'),'meta');

%% processing loop

% masks for radial averages
[radialMaskStack, edges] = makeRadialBinningMasks(meta);

% split the image up in big chunks for efficiency
maxBytes = (maxMemoryGB*1024^3);
bytesPerPixel = 2;
dataSize = meta.ySize*meta.xSize*meta.nChannels*bytesPerPixel;
nChunks = ceil(dataSize/maxBytes);

if nChunks > 1
    nRows = 2;
else
    nRows = 1;
end
nCols = ceil(nChunks/nRows);

xedge = (0:nCols)*(meta.xSize/nCols);
yedge = (0:nRows)*(meta.ySize/nRows);

% define the data structures to be filled in
preview = zeros(floor([2048 2048*meta.xSize/meta.ySize 4]));
mask = false([meta.ySize meta.xSize]);
colonies = [];
chunkColonies = {};
% L = 2048;
% bg = (2^16-1)*ones([L L meta.nChannels],'uint16');

chunkIdx = 0;

for n = 1:numel(yedge)-1
    for m = 1:numel(xedge)-1

        chunkIdx = chunkIdx + 1;

        disp(['reading chunk ' num2str(chunkIdx) ' of ' num2str(nChunks)])
        
        xmin = uint32(xedge(m) + 1); xmax = uint32(xedge(m+1));
        ymin = uint32(yedge(n) + 1); ymax = uint32(yedge(n+1));
        
        % add one sided overlap to make sure all colonies are completely
        % within at least one chunk
        % theoretically one radius should be enough but we need a little
        % margin
        if n < nRows 
            ymax = ymax + 1.25*max(meta.colRadiiPixel); 
        end
        if m < nCols
            xmax = xmax + 1.25*max(meta.colRadiiPixel);
        end
        chunkheight = ymax - ymin + 1;
        chunkwidth = xmax - xmin + 1;
        
        % for preview (thumbnail)
        ymaxprev = ceil(size(preview,1)*double(ymax)/meta.ySize);
        yminprev = ceil(size(preview,1)*double(ymin)/meta.ySize);
        xmaxprev = ceil(size(preview,2)*double(xmax)/meta.xSize);
        xminprev = ceil(size(preview,2)*double(xmin)/meta.xSize);
        
        img = zeros([chunkheight, chunkwidth, meta.nChannels],'uint16');
        for ci = 1:meta.nChannels
            tic
            disp(['reading channel ' num2str(ci)])
            img(:,:,ci) = imread(btfname,'Index',ci,'PixelRegion',{[ymin,ymax],[xmin, xmax]});
            preview(yminprev:ymaxprev,xminprev:xmaxprev, ci) = ...
                imresize(img(:,:,ci),[ymaxprev-yminprev+1, xmaxprev-xminprev+1]);
            toc
        end
        
        % determine background
        % bg = getBackground(bg, img, L);

        disp('determine threshold');
        if m == 1 && n == 1
            
            for ci = DAPIChannel
                
                imsize = 2048;
                forIlim = img(imsize+1:4*imsize,imsize+1:4*imsize,ci);
                minI = double(min(forIlim(:)));
                maxI = double(max(forIlim(:)));
                forIlim = mat2gray(forIlim);
                
                IlimDAPI = (stretchlim(forIlim)*maxI + minI)';
                t = 0.8*graythresh(forIlim)*maxI + minI;
            end
        end
        mask(ymin:ymax,xmin:xmax) = img(:,:,DAPIChannel) > 0.8*t;

        disp('find colonies');
        tic
        s = round(20/meta.xres);
        range = [xmin, xmax, ymin, ymax];
        [chunkColonies{chunkIdx}, cleanmask] = findColonies(mask, range, meta, s);
        toc

        disp('merge colonies')
        prevNColonies = numel(colonies);
        if prevNColonies > 0
            D = distmat(cat(1,colonies.center), chunkColonies{chunkIdx}.center);
            [i,j] = find(D < max(meta.colRadiiPixel)*meta.xres);
            chunkColonies{chunkIdx}(j) = [];
        end
        % add fields to enable concatenating
        colonies = cat(2,colonies,chunkColonies{chunkIdx});
        
        disp('process individual colonies')
        tic
        
        % channels to save to individual images
        if ~exist(fullfile(dataDir,'colonies'),'dir')
            mkdir(fullfile(dataDir,'colonies'));
        end

        nColonies = numel(colonies);
        
        for coli = prevNColonies+1:nColonies
            
            % store the ID so the colony object knows its position in the
            % array (used to then load the image etc)
            colonies(coli).ID = coli;
            
            fprintf('.');
            if mod(coli,60)==0
                fprintf('\n');
            end
            
            colDiamMicron = 2*colonies(coli).radiusMicron; 
            
            b = colonies(coli).boundingBox;
            colmask = mask(b(3):b(4),b(1):b(2));
            
            b(1:2) = b(1:2) - double(xmin - 1);
            b(3:4) = b(3:4) - double(ymin - 1);
            colimg = img(b(3):b(4),b(1):b(2), :);
            
            colmaskClean = cleanmask(b(3):b(4),b(1):b(2));

            % write colony image
            colonies(coli).saveImage(colimg, dataDir);

            % write DAPI separately for Ilastik
            colonies(coli).saveImage(colimg, dataDir, DAPIChannel);

            % do radial binning
            colType = find(meta.colRadiiMicron == colonies(coli).radiusMicron);
            N = size(radialMaskStack{colType},3);
            radavg = zeros([N meta.nChannels]);
            radstd = zeros([N meta.nChannels]);

            for ri = 1:N
                % for some reason linear indexing is faster than binary
                colbinmask = find(radialMaskStack{colType}(:,:,ri) & colmask);
                for ci = 1:meta.nChannels
                    imc = colimg(:,:,ci);
                    % most primitive background subtraction: minimal value
                    % within the colony
                    % min(imc(colmaskClean)) doubles the computatation time
                    imc = imc - min(imc(:));
                    imcbin = imc(colbinmask);
                    radavg(ri,ci) = mean(imcbin);
                    radstd(ri,ci) = std(double(imcbin));
                end
            end
            colonies(coli).radialAvg = radavg;
            colonies(coli).radialStd = radstd;
        end
        fprintf('\n');
        toc
    end
end

save(fullfile(dataDir,'colonies'), 'colonies');

%% visualize
    
figure,
imshow(imadjust(mat2gray(preview(:,:,DAPIChannel))))
hold on
CM = cat(1,colonies.center);
scale = size(preview,1)/meta.ySize;
CM(:,2) = CM(:,2)*scale;
CM(:,1) = CM(:,1)*scale;
radius = cat(1,colonies.radiusPixel)*scale;    
%scatter(CM(:,1),CM(:,2),'.r');
viscircles(CM,radius,'LineWidth',1)
hold off
saveas(gcf,fullfile(dataDir,'coloniesOverviewDAPI.png'));
hold on 
for i = 1:size(CM,1)
   text(CM(i,1),CM(i,2),num2str(i),'Color','red','BackgroundColor','white',...
       'Margin',1,'FontSize',5,'HorizontalAlignment','center'); 
end
hold off
saveas(gcf,fullfile(dataDir,'coloniesOverviewDAPIlabels.png'));

%% visualize
    
figure,
previewRGB = preview(:,:,2:4);
for i = 1:3
    previewRGB(:,:,i) = imadjust(mat2gray(previewRGB(:,:,i)));
end
channelPermutation = [3 1 2];
imshow(previewRGB(:,:,channelPermutation))
hold on
CM = cat(1,colonies.center);
scale = size(preview,1)/meta.ySize;
CM(:,2) = CM(:,2)*scale;
CM(:,1) = CM(:,1)*scale;
hold off
d = 80;
text(1,1,meta.antibodyNames{channelPermutation(1)+1},'Color','r','VerticalAlignment','top','BackgroundColor','white')
text(1,d,meta.antibodyNames{channelPermutation(2)+1},'Color','g','VerticalAlignment','top','BackgroundColor','white')
text(1,2*d,meta.antibodyNames{channelPermutation(3)+1},'Color','b','VerticalAlignment','top','BackgroundColor','white')
saveas(gcf,fullfile(dataDir,'coloniesOverview.png'));

%% read segmentation
% 
% make data in classifier 'copied to protect file'

load(fullfile(dataDir,'colonies'));

%%
coli = 4;

DAPI = colonies(coli).loadImage(dataDir, DAPIChannel);
seg = colonies(coli).loadSegmentation(dataDir);

figure, imshow(label2rgb(bwlabel(seg),'jet','k','shuffle'));

%%
options = struct('minAreaStd', 1, 'minSolidity',0);
seg2 = separateFusedNuclei(seg, options);
figure, imshow(label2rgb(bwlabel(seg2),'jet','k','shuffle'));

%% extract data using Ilastik segmentation

tic
for coli = 1:numel(colonies)
    
    % extract segmented data
    colonies(coli).extractData(dataDir);
    
    % radial binning of segmented data
    colType = find(meta.colRadiiMicron == colonies(coli).radiusMicron);
    colonies(coli).makeRadialAvgSeg(edges{colType})
end
toc

save(fullfile(dataDir,'colonies'), 'colonies');

%% display segmented radial profile

colRadii = cat(1,colonies.radiusMicron);
colonies1000idx = colRadii == 500;
colonies1000 = colonies(colonies1000idx);

i = find(meta.colRadiiMicron == 500);
r = imfilter(edges{i},[1 1]/2)*meta.xres;
r(1) = edges{i}(1)*meta.xres;
r = r(1:end-1);

colCat = cat(3,colonies1000(:).radialAvgSeg);
avg = mean(colCat,3);
avgNormalizedSeg = bsxfun(@rdivide, avg, avg(:,1));

plot(r, avgNormalizedSeg(:,2:4))
legend(meta.antibodyNames(2:4));
axis([min(r) max(r) 0 2]);

%% not segmented

figure,
colCat = cat(3,colonies1000(:).radialAvg);
avg = mean(colCat,3);
avgNormalized = bsxfun(@rdivide, avg, avg(:,1));

plot(r, avgNormalized(:,2:4))
legend(meta.antibodyNames(2:4));
axis([min(r) max(r) 0 2]);

%% compare

plot(r, avgNormalizedSeg(:,2:4))
axis([min(r) max(r) 0 2]);
hold on
plot(r, avgNormalized(:,2:4),'--')
hold off
legend(meta.antibodyNames(2:4));
title('segmented vs not segmented (dashed)')

%% look at single segmented colony

coli = 262;
avgSeg = colonies(coli).radialAvgSeg;
avgSegNormalized = bsxfun(@rdivide, avgSeg, avgSeg(:,1));
figure(3)
plot(r, avgSegNormalized(:,2:4))
legend(meta.antibodyNames(2:4))
axis([min(r) max(r) 0 3]);

%% compare non-segmented

avg = colonies(coli).radialAvg;
avgNormalized = bsxfun(@rdivide, avg, avg(:,1));
figure(2)
plot(r, avgNormalized(:,2:4))
legend(meta.antibodyNames(2:4))
axis([min(r) max(r) 0 3]);