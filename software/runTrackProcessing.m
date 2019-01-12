%runTrackProcessing(data, varargin) processes the track structure generated by runTracking()
%
% Inputs
%              data : list of movies, using the structure returned by loadConditionData.m
%
% Options
%          'Buffer' : Length of buffer readout before/after each track. Default: [5 5]
%       'Overwrite' : true|{false}. Overwrite previous processing result.
%          'Frames' : Index array of frames if runTracking was called on a subset of frames.
%      'Preprocess' : Perform preprocessing: discard single-frame tracks and decouple
%                       simple compound tracks. Default: true
%     'Postprocess' : Perform postprocessing: validation of tracks based on gap and
%                       buffer intensities; splitting of erroneously linked trajectories.
%                       Default: true
%  'ForceDiffractionLimited' : Treat only diffraction-limited signals as valid tracks.
%                              This is determined via a normality test on the residuals
%                              of the PSF fit.
%
% Example: runTrackProcessing(data, 'Buffer', 3);
%
% Notes: The buffer size influences the number of visible tracks. For a buffer size of
%        5 frames, only tracks initiating in frame 6 are treated as valid.
%
% Copyright (C) 2019, Danuser Lab - UTSouthwestern 
%
% This file is part of CMEAnalysis_Package.
% 
% CMEAnalysis_Package is free software: you can redistribute it and/or modify
% it under the terms of the GNU General Public License as published by
% the Free Software Foundation, either version 3 of the License, or
% (at your option) any later version.
% 
% CMEAnalysis_Package is distributed in the hope that it will be useful,
% but WITHOUT ANY WARRANTY; without even the implied warranty of
% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
% GNU General Public License for more details.
% 
% You should have received a copy of the GNU General Public License
% along with CMEAnalysis_Package.  If not, see <http://www.gnu.org/licenses/>.
% 
% 

% Francois Aguet, November 2010 (last modified 05/28/2013)

function runTrackProcessing(data, varargin)

ip = inputParser;
ip.CaseSensitive = false;
ip.addRequired('data', @isstruct);
ip.addParamValue('Buffer', [5 5], @(x) numel(x)==2);
ip.addParamValue('BufferAll', false, @islogical);
ip.addParamValue('Overwrite', false, @islogical);
ip.addParamValue('TrackerOutput', 'trackedFeatures.mat', @ischar);
ip.addParamValue('FileName', 'ProcessedTracks.mat', @ischar);
ip.addParamValue('DetectionFile', 'detection_v2.mat', @ischar);
ip.addParamValue('Frames', arrayfun(@(x) 1:x.movieLength, data, 'unif', 0), @(x) numel(unique(diff(x)))==1); %check that frame rate is constant
ip.addParamValue('Preprocess', true, @islogical);
ip.addParamValue('SlaveAmplitudeRatio', 0, @isnumeric);
ip.addParamValue('Postprocess', true, @islogical);
ip.addParamValue('CohortBounds_s', [10 20 40 60 80 100 125 150]); % used in post-proc
ip.addParamValue('Cutoff_f', 5, @isscalar);
ip.addParamValue('ForceDiffractionLimited', false, @islogical);
ip.parse(data, varargin{:});
overwrite = ip.Results.Overwrite;
frameIdx = ip.Results.Frames;
if ~iscell(frameIdx)
    frameIdx = {frameIdx};
end

parfor i = 1:length(data)
    if ~(exist([data(i).source filesep 'Tracking' filesep ip.Results.FileName],'file')==2) || overwrite %#ok<PFBNS>
        data(i) = main(data(i), frameIdx{i}, ip.Results);
    else
        fprintf('Tracks from %s have already been processed.\n', getShortPath(data(i)));
    end
end

function [data] = main(data, frameIdx, opts)
preprocess = opts.Preprocess;
postprocess = opts.Postprocess;
cohortBounds = opts.CohortBounds_s;


minLft = 2*data.framerate; % ignore single-frame tracks
cohortBounds(cohortBounds<=minLft) = [];
cohortBounds = [minLft cohortBounds data.movieLength*data.framerate];

dfile = [data.source 'Detection' filesep opts.DetectionFile];
if exist(dfile, 'file')==2
    detection = load([data.source 'Detection' filesep 'detection_v2.mat']);
else
    fprintf('runTrackProcessing: no detection data found for %s\n', getShortPath(data));
    return;
end
frameInfo = detection.frameInfo;
sigmaV = frameInfo(1).s;


ny = data.imagesize(1);
nx = data.imagesize(2);
nFrames = length(frameIdx);

alpha = 0.05;
kLevel = norminv(1-alpha/2.0, 0, 1); % ~2 std above background

%=================================
% Identify master/slave channels
%=================================
nCh = length(data.channels);
mCh = strcmp(data.source, data.channels);

sigma = sigmaV(mCh);
w4 = ceil(4*sigma);

%======================================================================
% Read and convert tracker output
%======================================================================
tPath = [data.source 'Tracking' filesep opts.TrackerOutput];
if exist(tPath, 'file')==2
    trackinfo = load(tPath);
    trackinfo = trackinfo.tracksFinal;
    nTracks = length(trackinfo);
else
    fprintf('runTrackProcessing: no tracking data found for %s\n', getShortPath(data));
    return;
end


%======================================================================
% Preprocessing
%======================================================================
if preprocess
    % Remove single-frame tracks
    bounds = arrayfun(@(i) i.seqOfEvents([1 end],1), trackinfo, 'unif', 0);
    rmIdx = diff(horzcat(bounds{:}), [], 1)==0;
    trackinfo(rmIdx) = [];
    nTracks = size(trackinfo, 1);
    
    %----------------------------------------------------------------------
    % Merge compound tracks with overlapping ends/starts
    %----------------------------------------------------------------------
    for i = 1:nTracks
        nSeg = size(trackinfo(i).tracksFeatIndxCG,1);
        if nSeg > 1
            seqOfEvents = trackinfo(i).seqOfEvents;
            tracksCoordAmpCG = trackinfo(i).tracksCoordAmpCG;
            tracksFeatIndxCG = trackinfo(i).tracksFeatIndxCG;
            
            rmIdx = [];
            for s = 1:nSeg
                iEvent = seqOfEvents(seqOfEvents(:,3)==s,:);
                parentSeg = iEvent(2,4);
                parentStartIdx = seqOfEvents(seqOfEvents(:,2)==1 & seqOfEvents(:,3)==parentSeg,1);
                
                % conditions for merging:
                % -current segment merges at end
                % -overlap between current segment and 'parent' it merges into: 1 frame
                if ~isnan(iEvent(2,4)) &&...
                        iEvent(2,1)-1==parentStartIdx
                    
                    % replace start index of parent with start index of current segment
                    seqOfEvents(seqOfEvents(:,3)==parentSeg & seqOfEvents(:,2)==1,1) = iEvent(1,1);
                    % remove current segment
                    seqOfEvents(seqOfEvents(:,3)==s,:) = [];
                    % assign segments that merge/split from current to parent
                    seqOfEvents(seqOfEvents(:,4)==s,4) = parentSeg;
                    
                    % use distance of points at overlap to assign
                    xMat = tracksCoordAmpCG(:,1:8:end);
                    yMat = tracksCoordAmpCG(:,2:8:end);
                    
                    % indexes in the 8-step matrices
                    iMat = repmat(1:size(xMat,2), [nSeg 1]).*~isnan(xMat);
                    
                    overlapIdx = setdiff(intersect(iMat(parentSeg,:), iMat(s,:)), 0);
                    if overlapIdx(1)>1 && overlapIdx(end)<seqOfEvents(end,1) && overlapIdx(1)~=(iEvent(1,1)-seqOfEvents(1,1)+1)
                        idx = [overlapIdx(1)-1 overlapIdx(end)+1];
                        if isnan(xMat(s,idx(1)))
                            idx(1) = overlapIdx(1);
                        end
                        if isnan(xMat(parentSeg,idx(2)))
                            idx(2) = overlapIdx(end);
                        end
                    elseif overlapIdx(1)==1 || overlapIdx(1)==(iEvent(1,1)-seqOfEvents(1,1)+1)
                        idx = [overlapIdx(1) overlapIdx(end)+1];
                        if isnan(xMat(parentSeg,idx(2)))
                            idx(2) = overlapIdx(end);
                        end
                    else
                        idx = [overlapIdx(1)-1 overlapIdx(end)];
                        if isnan(xMat(s,idx(1)))
                            idx(1) = overlapIdx(1);
                        end
                    end
                    xRef = interp1(idx, [xMat(s,idx(1)) xMat(parentSeg,idx(2))], overlapIdx);
                    yRef = interp1(idx, [yMat(s,idx(1)) yMat(parentSeg,idx(2))], overlapIdx);
                    
                    d = sqrt((xMat([s parentSeg],overlapIdx)-xRef).^2 + (yMat([s parentSeg],overlapIdx)-yRef).^2);
                    % remove overlap
                    rm = [s parentSeg];
                    rm = rm(d~=min(d));
                    iMat(rm,overlapIdx) = 0;
                    tracksCoordAmpCG(rm,(overlapIdx-1)*8+(1:8)) = NaN;
                    tracksFeatIndxCG(rm,overlapIdx) = 0;
                    tracksFeatIndxCG(parentSeg,iMat(s,:)~=0) = tracksFeatIndxCG(s,iMat(s,:)~=0);
                    
                    % concatenate segments
                    range8 = iMat(s,:);
                    range8(range8==0) = [];
                    range8 = (range8(1)-1)*8+1:range8(end)*8;
                    tracksCoordAmpCG(parentSeg, range8) = tracksCoordAmpCG(s, range8);
                    
                    rmIdx = [rmIdx s]; %#ok<AGROW>
                end % segment loop
            end
            rmIdx = unique(rmIdx);
            tracksFeatIndxCG(rmIdx,:) = [];
            tracksCoordAmpCG(rmIdx,:) = [];
            
            % re-order seqOfEvents
            [~,ridx] = sort(seqOfEvents(:,1));
            seqOfEvents = seqOfEvents(ridx,:);
            
            % indexes in seqOfEvents must be in order of segment appearance
            % replace with unique(seqOfEvents(:,3), 'stable') in future versions (>= 2012a)
            oldIdx = seqOfEvents(:,3);
            [~, m] = unique(oldIdx, 'first');
            % mapping: oldIdx(sort(m)) -> 1:nSeg
            idxMap = oldIdx(sort(m));
            [~,newIdx] = ismember(oldIdx, idxMap);
            seqOfEvents(:,3) = newIdx;
            % replace parent indexes
            [~,newIdx] = ismember(seqOfEvents(:,4), idxMap);
            seqOfEvents(:,4) = newIdx;
            seqOfEvents(seqOfEvents(:,4)==0,4) = NaN;
            
            % re-assign to trackinfo, re-arrange with new index
            [~,ridx] = sort(idxMap);
            [~,lidx] = sort(ridx);
            trackinfo(i).seqOfEvents = seqOfEvents;
            trackinfo(i).tracksCoordAmpCG = tracksCoordAmpCG(lidx,:);
            trackinfo(i).tracksFeatIndxCG = tracksFeatIndxCG(lidx,:);
        end
    end
end % preprocess
%======================================================================

% Set up track structure
tracks(1:nTracks) = struct('t', [], 'f', [],...
    'x', [], 'y', [], 'A', [], 'c', [],...
    'x_pstd', [], 'y_pstd', [], 'A_pstd', [], 'c_pstd', [],...
    'sigma_r', [], 'SE_sigma_r', [],...
    'pval_Ar', [], 'isPSF', [],...
    'tracksFeatIndxCG', [], 'gapVect', [], 'gapStatus', [], 'gapIdx', [], 'seqOfEvents', [],...
    'nSeg', [], 'visibility', [], 'lifetime_s', [], 'start', [], 'end', [],...
    'startBuffer', [], 'endBuffer', [], 'MotionAnalysis', []);

% track field names
idx = structfun(@(i) size(i,2)==size(frameInfo(1).x,2), frameInfo(1));
mcFieldNames = fieldnames(frameInfo);
[~,loc] = ismember({'s', 'x_init', 'y_init', 'xCoord', 'yCoord', 'amp', 'dRange'}, mcFieldNames);
idx(loc(loc~=0)) = false;
mcFieldNames = mcFieldNames(idx);
mcFieldSizes = structfun(@(i) size(i,1), frameInfo(1));
mcFieldSizes = mcFieldSizes(idx);
bufferFieldNames = {'t', 'f', 'x', 'y', 'A', 'c', 'A_pstd', 'c_pstd', 'sigma_r', 'SE_sigma_r', 'pval_Ar'};

%==============================
% Loop through tracks
%==============================
buffer = repmat(opts.Buffer, [nTracks,1]);

fprintf('Processing tracks (%s) - converting tracker output:     ', getShortPath(data));
for k = 1:nTracks
    
    % convert/assign structure fields
    seqOfEvents = trackinfo(k).seqOfEvents;
    tracksFeatIndxCG = trackinfo(k).tracksFeatIndxCG; % index of the feature in each frame
    nSeg = size(tracksFeatIndxCG,1);
    
    segLengths = NaN(1,nSeg);
    
    % Remove short merging/splitting branches
    msIdx = NaN(1,nSeg);
    for s = 1:nSeg
        idx = seqOfEvents(:,3)==s;
        ievents = seqOfEvents(idx, :);
        bounds = ievents(:,1); % beginning & end of this segment
        if ~isnan(ievents(2,4))
            bounds(2) = bounds(2)-1; % correction if end is a merge
        end
        segLengths(s) = bounds(2)-bounds(1)+1;
        
        % remove short (<4 frames) merging/splitting branches if:
        % -the segment length is a single frame
        % -the segment is splitting and merging from/to the same parent
        % -short segment merges, segment starts after track start
        % -short segment splits, segment ends before track end
        msIdx(s) = segLengths(s)==1 || (segLengths(s)<4 && ( diff(ievents(:,4))==0 ||...
            (isnan(ievents(1,4)) && ~isnan(ievents(2,4)) && ievents(1,1)>seqOfEvents(1,1)) ||...
            (isnan(ievents(2,4)) && ~isnan(ievents(1,4)) && ievents(2,1)<seqOfEvents(end,1)) ));
    end
    if preprocess && nSeg>1
        segIdx = find(msIdx==0); % index segments to retain (avoids re-indexing segments)
        nSeg = numel(segIdx); % update segment #
        msIdx = find(msIdx);
        if ~isempty(msIdx)
            tracksFeatIndxCG(msIdx,:) = [];
            seqOfEvents(ismember(seqOfEvents(:,3), msIdx),:) = [];
        end
        segLengths = segLengths(segIdx);
    else
        segIdx = 1:nSeg;
    end
    
    tracks(k).nSeg = nSeg;
    firstIdx = trackinfo(k).seqOfEvents(1,1);
    lastIdx = trackinfo(k).seqOfEvents(end,1);
    
    tracks(k).lifetime_s = (lastIdx-firstIdx+1)*data.framerate;
    tracks(k).start = firstIdx;
    tracks(k).end = lastIdx;
    
    tracks(k).seqOfEvents = seqOfEvents;
    tracks(k).tracksFeatIndxCG = tracksFeatIndxCG; % index of the feature in each frame
    
    if (buffer(k,1)<tracks(k).start) && (tracks(k).end<=nFrames-buffer(k,2)) % complete tracks
        tracks(k).visibility = 1;
    elseif tracks(k).start==1 && tracks(k).end==nFrames % persistent tracks
        tracks(k).visibility = 3;
    else
        tracks(k).visibility = 2; % incomplete tracks
    end
    
    %==============================================================================
    % Initialize arrays
    %==============================================================================
    
    % Segments are concatenated into single arrays, separated by NaNs.
    fieldLength = sum(segLengths)+nSeg-1;
    for f = 1:length(mcFieldNames)
        tracks(k).(mcFieldNames{f}) = NaN(mcFieldSizes(f), fieldLength);
    end
    tracks(k).t = NaN(1, fieldLength);
    tracks(k).f = NaN(1, fieldLength);
    
    if fieldLength>1
        
        % start buffer size for this track
        sb = firstIdx - max(1, firstIdx-buffer(k,1));
        if isinf(buffer(k,2))
            eb = data.movieLength-lastIdx;
            buffer(k,2) = eb;
        else
            eb = min(lastIdx+buffer(k,2), data.movieLength)-lastIdx;
        end
        if sb>0 && (tracks(k).visibility==1 || opts.BufferAll)
            for f = 1:length(bufferFieldNames)
                tracks(k).startBuffer.(bufferFieldNames{f}) = NaN(nCh, sb);
            end
        end
        if eb>0 && (tracks(k).visibility==1 || opts.BufferAll)
            for f = 1:length(bufferFieldNames)
                tracks(k).endBuffer.(bufferFieldNames{f}) = NaN(nCh, eb);
            end
        end
    end
    
    %==============================================================================
    % Read amplitude & background from detectionResults.mat (localization results)
    %==============================================================================
    delta = [0 cumsum(segLengths(1:end-1))+(1:nSeg-1)];
    
    for s = 1:nSeg
        ievents = seqOfEvents(seqOfEvents(:,3)==segIdx(s), :);
        bounds = ievents(:,1);
        if ~isnan(ievents(2,4))
            bounds(2) = bounds(2)-1;
        end
        
        nf = bounds(2)-bounds(1)+1;
        frameRange = frameIdx(bounds(1):bounds(2)); % relative to movie (also when movie is subsampled)
        
        for i = 1:length(frameRange)
            idx = tracksFeatIndxCG(s, frameRange(i) - tracks(k).start + 1); % -> relative to IndxCG
            if idx ~= 0 % if not a gap, get detection values
                for f = 1:length(mcFieldNames)
                    tracks(k).(mcFieldNames{f})(:,i+delta(s)) = frameInfo(frameRange(i)).(mcFieldNames{f})(:,idx);
                end
            end
        end
        tracks(k).t(delta(s)+(1:nf)) = (bounds(1)-1:bounds(2)-1)*data.framerate;
        tracks(k).f(delta(s)+(1:nf)) = frameRange;
    end
    
    fprintf('\b\b\b\b%3d%%', round(100*k/nTracks));
end
fprintf('\n');

% remove tracks that fall into image boundary
minx = round(arrayfun(@(t) min(t.x(:)), tracks));
maxx = round(arrayfun(@(t) max(t.x(:)), tracks));
miny = round(arrayfun(@(t) min(t.y(:)), tracks));
maxy = round(arrayfun(@(t) max(t.y(:)), tracks));

idx = minx<=w4 | miny<=w4 | maxx>nx-w4 | maxy>ny-w4;
tracks(idx) = [];
buffer(idx,:) = [];
nTracks = numel(tracks);

%=======================================
% Interpolate gaps and clean up tracks
%=======================================
fprintf('Processing tracks (%s) - classification:     ', getShortPath(data));
for k = 1:nTracks
    
    % gap locations in 'x' for all segments
    gapVect = isnan(tracks(k).x(mCh,:)) & ~isnan(tracks(k).t);
    tracks(k).gapVect = gapVect;
    
    %=================================
    % Determine track and gap status
    %=================================
    sepIdx = isnan(tracks(k).t);
    
    gapCombIdx = diff(gapVect | sepIdx);
    gapStarts = find(gapCombIdx==1)+1;
    gapEnds = find(gapCombIdx==-1);
    gapLengths = gapEnds-gapStarts+1;
    
    segmentIdx = diff([0 ~(gapVect | sepIdx) 0]); % these variables refer to segments between gaps
    segmentStarts = find(segmentIdx==1);
    segmentEnds = find(segmentIdx==-1)-1;
    segmentLengths = segmentEnds-segmentStarts+1;
    
    % loop over gaps
    nGaps = numel(gapLengths);
    if nGaps>0
        gv = 1:nGaps;
        gapStatus = 5*ones(1,nGaps);
        % gap valid if segments that precede/follow are > 1 frame or if gap is a single frame
        gapStatus(segmentLengths(gv)>1 & segmentLengths(gv+1)>1 | gapLengths(gv)==1) = 4;
        
        sepIdx = sepIdx(gapStarts)==1;
        gapStatus(sepIdx) = [];
        gapStarts(sepIdx) = [];
        gapEnds(sepIdx) = [];
        nGaps = numel(gapStatus);
        
        % fill position information for valid gaps using linear interpolation
        for g = 1:nGaps
            borderIdx = [gapStarts(g)-1 gapEnds(g)+1];
            gacombIdx = gapStarts(g):gapEnds(g);
            for c = 1:nCh
                tracks(k).x(c, gacombIdx) = interp1(borderIdx, tracks(k).x(c, borderIdx), gacombIdx);
                tracks(k).y(c, gacombIdx) = interp1(borderIdx, tracks(k).y(c, borderIdx), gacombIdx);
                tracks(k).A(c, gacombIdx) = interp1(borderIdx, tracks(k).A(c, borderIdx), gacombIdx);
                tracks(k).c(c, gacombIdx) = interp1(borderIdx, tracks(k).c(c, borderIdx), gacombIdx);
            end
        end
        tracks(k).gapStatus = gapStatus;
        tracks(k).gapIdx = arrayfun(@(i) gapStarts(i):gapEnds(i), 1:nGaps, 'unif', 0);
    end
    fprintf('\b\b\b\b%3d%%', round(100*k/nTracks));
end
fprintf('\n');

%====================================================================================
% Generate buffers before and after track, estimate gap values
%====================================================================================
% Gap map for fast indexing
gapMap = zeros(nTracks, data.movieLength);
for k = 1:nTracks
    gapMap(k, tracks(k).f(tracks(k).gapVect==1)) = 1;
end

% for buffers:
trackStarts = [tracks.start];
trackEnds = [tracks.end];
fullTracks = [tracks.visibility]==1 | (opts.BufferAll & [tracks.visibility]==2);

fprintf('Processing tracks (%s) - gap interpolation, buffer readout:     ', getShortPath(data));
for f = 1:data.movieLength
    if iscell(data.framePaths{mCh})
        mask = double(imread(data.maskPaths{f}));
    else
        mask = double(readtiff(data.maskPaths, f));
    end
    labels = bwlabel(mask~=0);
    
    for ch = 1:nCh
        if iscell(data.framePaths{mCh})
            frame = double(imread(data.framePaths{ch}{f}));
        else
            frame = double(readtiff(data.framePaths{ch}, f));
        end
        
        %------------------------
        % Gaps
        %------------------------
        % tracks with valid gaps visible in current frame
        currentGapsIdx = find(gapMap(:,f));
        for ki = 1:numel(currentGapsIdx)
            k = currentGapsIdx(ki);
            
            % index in the track structure (.x etc)
            idxList = find(tracks(k).f==f & tracks(k).gapVect==1);
            for l = 1:numel(idxList)
                idx = idxList(l);
                [t0] = interpTrack(tracks(k).x(ch,idx), tracks(k).y(ch,idx), frame, labels,...
                    tracks(k).A(ch,idx), tracks(k).c(ch,idx), sigmaV(mCh), sigmaV(ch), kLevel);
                tracks(k) = mergeStructs(tracks(k), ch, idx, t0);
            end
        end
        
        %------------------------
        % start buffer
        %------------------------
        % tracks with start buffers in this frame
        cand = max(1, trackStarts-buffer(:,1)')<=f & f<trackStarts;
        % corresponding tracks, only if status = 1
        currentBufferIdx = find(cand & fullTracks);
        
        for ki = 1:length(currentBufferIdx)
            k = currentBufferIdx(ki);
            [t0] = interpTrack(tracks(k).x(ch,1), tracks(k).y(ch,1), frame, labels,...
                tracks(k).A(ch,1), tracks(k).c(ch,1), sigmaV(mCh), sigmaV(ch), kLevel);
            bi = f - max(1, tracks(k).start-buffer(k,1)) + 1;
            tracks(k).startBuffer = mergeStructs(tracks(k).startBuffer, ch, bi, t0);
        end
        
        %------------------------
        % end buffer
        %------------------------
        % segments with end buffers in this frame
        cand = trackEnds<f & f<=min(data.movieLength, trackEnds+buffer(:,2)');
        % corresponding tracks
        currentBufferIdx = find(cand & fullTracks);
        
        for ki = 1:length(currentBufferIdx)
            k = currentBufferIdx(ki);
            [t0] = interpTrack(tracks(k).x(ch,end), tracks(k).y(ch,end), frame, labels,...
                tracks(k).A(ch,end), tracks(k).c(ch,end), sigmaV(mCh), sigmaV(ch), kLevel);
            bi = f - tracks(k).end;
            tracks(k).endBuffer = mergeStructs(tracks(k).endBuffer, ch, bi, t0);
        end
        fprintf('\b\b\b\b%3d%%', round(100*(ch + (f-1)*nCh)/(nCh*data.movieLength)));
    end
end
fprintf('\n');

%----------------------------------
% Add time vectors to buffers
%----------------------------------
for k = 1:nTracks
    % add buffer time vectors
    if ~isempty(tracks(k).startBuffer)
        b = size(tracks(k).startBuffer.x,2);
        tracks(k).startBuffer.f = (-b:-1) + tracks(k).start;
        tracks(k).startBuffer.t = ((-b:-1) + tracks(k).start-1) * data.framerate;
    end
    if ~isempty(tracks(k).endBuffer)
        b = size(tracks(k).endBuffer.x,2);
        tracks(k).endBuffer.f = tracks(k).end + (1:b);
        tracks(k).endBuffer.t = (tracks(k).end + (1:b)-1) * data.framerate;
    end
end


%============================================================================
% Run post-processing
%============================================================================
if postprocess
    %----------------------------------------------------------------------------
    % I. Assign category to each track
    %----------------------------------------------------------------------------
    % Categories:
    % Ia)  Single tracks with valid gaps
    % Ib)  Single tracks with invalid gaps
    % Ic)  Single tracks cut at beginning or end
    % Id)  Single tracks, persistent
    % IIa) Compound tracks with valid gaps
    % IIb) Compound tracks with invalid gaps
    % IIc) Compound tracks cut at beginning or end
    % IId) Compound tracks, persistent
    
    % The categories correspond to index 1-8, in the above order
    
    validGaps = arrayfun(@(t) max([t.gapStatus 4]), tracks)==4;
    singleIdx = [tracks.nSeg]==1;
    vis = [tracks.visibility];
    
    mask_Ia = singleIdx & validGaps & vis==1;
    mask_Ib = singleIdx & ~validGaps & vis==1;
    idx_Ia = find(mask_Ia);
    idx_Ib = find(mask_Ib);
    trackLengths = [tracks.end]-[tracks.start]+1;
    
    C = [mask_Ia;
        2*mask_Ib;
        3*(singleIdx & vis==2);
        4*(singleIdx & vis==3);
        5*(~singleIdx & validGaps & vis==1);
        6*(~singleIdx & ~validGaps & vis==1);
        7*(~singleIdx & vis==2);
        8*(~singleIdx & vis==3)];
    
    C = num2cell(sum(C,1));
    % assign category
    [tracks.catIdx] = deal(C{:});
    
    %----------------------------------------------------------------------------
    % II. Identify diffraction-limited tracks (CCPs)
    %----------------------------------------------------------------------------
    % Criterion: if all detected points pass AD-test, then track is a CCP.
    % (gaps in the track are not considered in this test)
    
    % # diffraction-limited points per track (can be different from track length for compound tracks!)
    nPl = arrayfun(@(i) nansum(i.hval_AD(mCh,:) .* ~i.gapVect), tracks);
    isCCP = num2cell(nPl==0);
    [tracks.isCCP] = deal(isCCP{:});
    isCCP = [isCCP{:}];
    
    % average mask area per track
    % meanMaskAreaCCP = arrayfun(@(i) nanmean(i.maskN), tracks(isCCP));
    % meanMaskAreaNotCCP = arrayfun(@(i) nanmean(i.maskN), tracks(~isCCP));
    
    %----------------------------------------------------------------------------
    % III. Process 'Ib' tracks:
    %----------------------------------------------------------------------------
    % Reference distribution: class Ia tracks
    % Determine critical max. intensity values from class Ia tracks, per lifetime cohort
    
    % # cohorts
    nc = numel(cohortBounds)-1;
    
    % max intensities of all 'Ia' tracks
    maxInt = arrayfun(@(i) max(i.A(mCh,:)), tracks(idx_Ia));
    maxIntDistr = cell(1,nc);
    mappingThresholdMaxInt = zeros(1,nc);
    lft_Ia = [tracks(idx_Ia).lifetime_s];
    for i = 1:nc
        maxIntDistr{i} = maxInt(cohortBounds(i)<=lft_Ia & lft_Ia<cohortBounds(i+1));
        % critical values for test
        mappingThresholdMaxInt(i) = prctile(maxIntDistr{i}, 2.5);
    end
    
    % get lifetime histograms before change
    processingInfo.lftHists.before = getLifetimeHistogram(data, tracks);
    
    % Criteria for mapping:
    % - max intensity must be within 2.5th percentile of max. intensity distribution for 'Ia' tracks
    % - lifetime >= 5 frames (at 4 frames: track = [x o o x])
    
    % assign category I to tracks that match criteria
    for k = 1:numel(idx_Ib);
        i = idx_Ib(k);
        
        % get cohort idx for this track (logical)
        cIdx = cohortBounds(1:nc)<=tracks(i).lifetime_s & tracks(i).lifetime_s<cohortBounds(2:nc+1);
        
        if max(tracks(i).A(mCh,:)) >= mappingThresholdMaxInt(cIdx) && trackLengths(i)>4
            tracks(i).catIdx = 1;
        end
    end
    processingInfo.lftHists.after = getLifetimeHistogram(data, tracks);
    
    %----------------------------------------------------------------------------
    % IV. Apply threshold on buffer intensities
    %----------------------------------------------------------------------------
    % Conditions:
    % - the amplitude in at least 2 consecutive frames must be within background in each buffer
    % - the maximum buffer amplitude must be smaller than the maximum track amplitude
    Tbuffer = 2;
    
    % loop through cat. Ia tracks
    idx_Ia = find([tracks.catIdx]==1);
    for k = 1:numel(idx_Ia)
        i = idx_Ia(k);
        
        % H0: A = background (p-value >= 0.05)
        sbin = tracks(i).startBuffer.pval_Ar(mCh,:) < 0.05; % positions with signif. signal
        ebin = tracks(i).endBuffer.pval_Ar(mCh,:) < 0.05;
        [sl, sv] = binarySegmentLengths(sbin);
        [el, ev] = binarySegmentLengths(ebin);
        if ~any(sl(sv==0)>=Tbuffer) || ~any(el(ev==0)>=Tbuffer) ||...
                max([tracks(i).startBuffer.A(mCh,:)+tracks(i).startBuffer.c(mCh,:)...
                tracks(i).endBuffer.A(mCh,:)+tracks(i).endBuffer.c(mCh,:)]) >...
                max(tracks(i).A(mCh,:)+tracks(i).c(mCh,:))
            tracks(i).catIdx = 2;
        end
    end
    
    %----------------------------------------------------------------------------
    % V. Assign Cat. Ib to tracks that are not diffraction-limited CCPs
    %----------------------------------------------------------------------------
    if opts.ForceDiffractionLimited
        [tracks([tracks.catIdx]==1 & ~isCCP).catIdx] = deal(2);
    end
    
    %----------------------------------------------------------------------------
    % VI. Cut tracks with sequential events (hotspots) into individual tracks
    %----------------------------------------------------------------------------
    splitCand = find([tracks.catIdx]==1 & arrayfun(@(i) ~isempty(i.gapIdx), tracks) & trackLengths>4);
    
    % Loop through tracks and test whether gaps are at background intensity
    rmIdx = []; % tracks to remove from list after splitting
    newTracks = [];
    for i = 1:numel(splitCand);
        k = splitCand(i);
        
        % all gaps
        gapIdx = [tracks(k).gapIdx{:}];
        
        % # residual points
        npx = round((tracks(k).sigma_r(mCh,:) ./ tracks(k).SE_sigma_r(mCh,:)).^2/2+1);
        npx = npx(gapIdx);
        
        % t-test on gap amplitude
        A = tracks(k).A(mCh, gapIdx);
        sigma_A = tracks(k).A_pstd(mCh, gapIdx);
        T = (A-sigma_A)./(sigma_A./sqrt(npx));
        pval = tcdf(T, npx-1);
        
        % gaps with signal below background level: candidates for splitting
        splitIdx = pval<0.05;
        gapIdx = gapIdx(splitIdx==1);
        
        % new segments must be at least 5 frames
        delta = diff([1 gapIdx trackLengths(k)]);
        gapIdx(delta(1:end-1)<5 | delta(2:end)<5) = [];
        
        ng = numel(gapIdx);
        splitIdx = zeros(1,ng);
        
        for g = 1:ng
            
            % split track at gap position
            x1 = tracks(k).x(mCh, 1:gapIdx(g)-1);
            y1 = tracks(k).y(mCh, 1:gapIdx(g)-1);
            x2 = tracks(k).x(mCh, gapIdx(g)+1:end);
            y2 = tracks(k).y(mCh, gapIdx(g)+1:end);
            mux1 = median(x1);
            muy1 = median(y1);
            mux2 = median(x2);
            muy2 = median(y2);
            
            % projections
            v = [mux2-mux1; muy2-muy1];
            v = v/norm(v);
            
            % x1 in mux1 reference
            X1 = [x1-mux1; y1-muy1];
            sp1 = sum(repmat(v, [1 numel(x1)]).*X1,1);
            
            % x2 in mux1 reference
            X2 = [x2-mux1; y2-muy1];
            sp2 = sum(repmat(v, [1 numel(x2)]).*X2,1);
            
            % test whether projections are distinct distributions of points
            % may need to be replaced by outlier-robust version
            if mean(sp1)<mean(sp2) && prctile(sp1,95)<prctile(sp2,5)
                splitIdx(g) = 1;
            elseif mean(sp1)>mean(sp2) && prctile(sp1,5)>prctile(sp2,95)
                splitIdx(g) = 1;
            else
                splitIdx(g) = 0;
            end
        end
        gapIdx = gapIdx(splitIdx==1);
        
        if ~isempty(gapIdx)
            % store index of parent track, to be removed at end
            rmIdx = [rmIdx k]; %#ok<AGROW>
            
            % new tracks
            splitTracks = cutTrack(tracks(k), gapIdx);
            newTracks = [newTracks splitTracks]; %#ok<AGROW>
        end
    end
    % final assignment
    % fprintf('# tracks cut: %d\n', numel(rmIdx));
    tracks(rmIdx) = [];
    tracks = [tracks newTracks];
    
    % remove tracks with more gaps than frames
    nGaps = arrayfun(@(i) sum(i.gapVect), tracks);
    trackLengths = [tracks.end]-[tracks.start]+1;
    
    % fprintf('# tracks with >50%% gaps: %d\n', sum(nGaps./trackLengths>=0.5));
    [tracks(nGaps./trackLengths>=0.5).catIdx] = deal(2);
    
    
    % Displacement statistics: remove tracks with >4 large frame-to-frame displacements
    nt = numel(tracks);
    dists = cell(1,nt);
    medianDist = zeros(1,nt);
    for i = 1:nt
        dists{i} = sqrt((tracks(i).x(mCh,2:end) - tracks(i).x(mCh,1:end-1)).^2 +...
            (tracks(i).y(mCh,2:end) - tracks(i).y(mCh,1:end-1)).^2);
        medianDist(i) = nanmedian(dists{i});
    end
    for i = 1:nt
        if sum(dists{i}>prctile(medianDist, 95))>4 && tracks(i).catIdx==1
            tracks(i).catIdx = 2;
        end
    end
    
    
    %==========================================
    % Compute displacement statistics
    %==========================================
    % Only on valid tracks (Cat. Ia)
    trackIdx = find([tracks.catIdx]<5);
    fprintf('Processing tracks (%s) - calculating statistics:     ', getShortPath(data));
    for ki = 1:numel(trackIdx)
        k = trackIdx(ki);
        x = tracks(k).x(mCh,:);
        y = tracks(k).y(mCh,:);
        tracks(k).MotionAnalysis.totalDisplacement = sqrt((x(end)-x(1))^2 + (y(end)-y(1))^2);
        % calculate MSD
        L = 10;
        msdVect = NaN(1,L);
        msdStdVect = NaN(1,L);
        for l = 1:min(L, numel(x)-1)
            tmp = (x(1+l:end)-x(1:end-l)).^2 + (y(1+l:end)-y(1:end-l)).^2;
            msdVect(l) = mean(tmp);
            msdStdVect(l) = std(tmp);
        end
        tracks(k).MotionAnalysis.MSD = msdVect;
        tracks(k).MotionAnalysis.MSDstd = msdStdVect;
        fprintf('\b\b\b\b%3d%%', round(100*ki/numel(trackIdx)));
    end
    fprintf('\n');
    
    fprintf('Processing for %s complete - valid/total tracks: %d/%d (%.1f%%).\n',...
        getShortPath(data), sum([tracks.catIdx]==1), numel(tracks), sum([tracks.catIdx]==1)/numel(tracks)*100);
    
end % postprocessing

%===============================================================================
% Classify slave channel signals
%===============================================================================
if nCh>1
    tracks = runSlaveChannelClassification(data, tracks,'amplitudeRatio',opts.SlaveAmplitudeRatio);
    
    idx = [tracks.catIdx]==1 & [tracks.lifetime_s]>=data.framerate*opts.Cutoff_f;
    nPosM = sum([tracks(idx).significantMaster],2);
    nPosS = sum([tracks(idx).significantSlave],2);
    for c = setdiff(1:nCh,mCh)
        if ~isempty(nPosM)
            fprintf('Ch. %d positive tracks as master: %.2f %% (%d/%d valid, %d total)\n', c, 100*nPosM(c)/sum(idx), nPosM(c), sum(idx), nt);
            fprintf('Ch. %d positive tracks as slave:  %.2f %% (%d/%d valid, %d total)\n', c, 100*nPosS(c)/sum(idx), nPosS(c), sum(idx), nt);
        end
    end
end

%===============================================================================
% Save results
%===============================================================================
if ~(exist([data.source 'Tracking'], 'dir')==7)
    mkdir([data.source 'Tracking']);
end
if isunix
    cmd = ['svn info ' mfilename('fullpath') '.m | grep "Last Changed Rev"'];
    [status,rev] = system(cmd);
    if status==0
        rev = regexp(rev, '\d+', 'match');
        processingInfo.revision = rev{1};
    end
end
processingInfo.procFlag = [preprocess postprocess];
save([data.source 'Tracking' filesep opts.FileName], 'tracks', 'processingInfo');




% calculate track fields for gap or buffer position
function [ps] = interpTrack(x, y, frame, labels, ai, ci, sigma, sigmaCh, kLevel)

xi = round(x);
yi = round(y);

w2 = ceil(2*sigma);
w4 = ceil(4*sigma);

maskWindow = labels(yi-w4:yi+w4, xi-w4:xi+w4);
maskWindow(maskWindow==maskWindow(w4+1,w4+1)) = 0;

window = double(frame(yi-w4:yi+w4, xi-w4:xi+w4));
window(maskWindow~=0) = NaN;

x0 = x-xi;
y0 = y-yi;
npx = sum(isfinite(window(:)));
[prm, prmStd, ~, res] = fitGaussian2D(window, [x0 y0 ai sigmaCh ci], 'xyAc');
dx = prm(1);
dy = prm(2);
if (dx > -w2 && dx < w2 && dy > -w2 && dy < w2)
    ps.x = xi+dx;
    ps.y = yi+dy;
    ps.A_pstd = prmStd(3);
    ps.c_pstd = prmStd(4);
else
    [prm, prmStd, ~, res] = fitGaussian2D(window, [x0 y0 ai sigmaCh ci], 'Ac');
    ps.x = x;
    ps.y = y;
    ps.A_pstd = prmStd(1);
    ps.c_pstd = prmStd(2);
end
ps.A = prm(3);
ps.c = prm(5);

ps.sigma_r = res.std;
ps.SE_sigma_r = res.std/sqrt(2*(npx-1));

SE_r = ps.SE_sigma_r * kLevel;

ps.hval_AD = res.hAD;

df2 = (npx-1) * (ps.A_pstd.^2 + SE_r.^2).^2 ./...
    (ps.A_pstd.^4 + SE_r.^4);

scomb = sqrt((ps.A_pstd.^2 + SE_r.^2)/npx);
T = (ps.A - res.std*kLevel) ./ scomb;
ps.pval_Ar = tcdf(-T, df2);



function ps = mergeStructs(ps, ch, idx, cs)

cn = fieldnames(cs);
for f = 1:numel(cn)
    ps.(cn{f})(ch,idx) = cs.(cn{f});
end
