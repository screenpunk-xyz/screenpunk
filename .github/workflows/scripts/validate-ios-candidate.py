#!/usr/bin/env python3
"""Internal staging candidate policy. No credentials or networking."""
import copy

FLAG = 'SCREENPUNK_INTERNAL_STAGING_CONCURRENT_CANDIDATE'
MARKER = 'ScreenpunkInternalConcurrentControlCandidate'
MODE = 'ScreenpunkConcurrentControlBuildMode'
COMPILE_FLAG = 'ScreenpunkConcurrentControlCompileFlag'
VALUE = 'internal-staging-concurrent-v1'


def candidate_input(environ):
    value = environ.get('IOS_INTERNAL_CONCURRENT_CANDIDATE', 'false')
    if value not in ('true', 'false'):
        raise ValueError('InternalCandidateInput')
    return value == 'true'


def validate_candidate(info, candidate):
    if not isinstance(info, dict) or type(candidate) is not bool:
        raise ValueError('InternalCandidateConfiguration')
    if info.get(MODE) != ('internal-staging-candidate' if candidate else 'ordinary'):
        raise ValueError('InternalCandidateBuildMode')
    if info.get(COMPILE_FLAG) != (FLAG if candidate else 'disabled'):
        raise ValueError('InternalCandidateCompileFlag')
    if candidate:
        if (info.get(MARKER) != VALUE
                or info.get('ScreenpunkCloudAPIOrigin') != 'https://staging.screenpunk.xyz'
                or info.get('ScreenpunkCloudFirebaseProjectID') != 'screenpunk-stg-6f6e615a'
                or info.get('ScreenpunkCloudBundleID') != 'xyz.screenpunk.ios'):
            raise ValueError('InternalCandidateStagingBinding')
    elif MARKER in info:
        raise ValueError('UnexpectedInternalCandidateMarker')


def derived_info(validated_original, candidate):
    # Caller must first validate exact protected original SHA and generator equality.
    if any(key in validated_original for key in (MARKER, MODE, COMPILE_FLAG)):
        raise ValueError('ProtectedOriginalContainsCandidateMarker')
    info = copy.deepcopy(validated_original)
    info[COMPILE_FLAG] = FLAG if candidate else 'disabled'
    info[MODE] = 'internal-staging-candidate' if candidate else 'ordinary'
    if candidate:
        info[MARKER] = VALUE
    validate_candidate(info, candidate)
    return info
