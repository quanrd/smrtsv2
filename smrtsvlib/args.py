"""
Defines a dictionary of command-line options.
"""

args_dict = dict()


###########
# Options #
###########

#
# Option to the base parser
#

args_dict['cluster_config'] = {
    'help': 'JSON/YAML file specifying cluster configuration parameters to pass to Snakemake\'s '
            '--cluster-config option'
}

args_dict['distribute'] = {
    'action': 'store_true',
    'help': 'Distribute analysis to Grid Engine-style cluster.'
}

args_dict['drmaalib'] = {
    'help': 'For jobs that are distributed, this is the location to the DRMAA library (libdrmaa.so) '
            'installed with Grid Engine. If DRMAA_LIBRARY_PATH is already set in the environment, '
            'then this option is not required.'
}

args_dict['dryrun'] = {
    'action': 'store_true',
    'help': 'Print commands that will run without running them.'
}

args_dict['jobs'] = {
    'type': int,
    'default': 1,
    'help': 'Number of jobs to run simultaneously.'
}

args_dict['job_prefix'] = {
    'default': None,
    'help': 'Prepend this string to submitted job names. Can be used to distinguish jobs from multiple runs.'
}

args_dict['keep_going'] = {
    'action': 'store_true',
    'default': False,
    'help': 'When a step in a Snakemake pipeline fails, do not stop the pipeline. This will cause Snakemake '
            'to continue submitting new jobs until it cannot continue.'
}

args_dict['log'] = {
    'help': 'Cluster log file directory for distributed jobs. Each SMRT-SV command defaults to a log directory in its '
            'output subdirectory. The genotyper will use "log" in its working directory. If this value is set, all '
            'logs from all commands are written to the specified directory.'
}

args_dict['nt'] = {
    'action': 'store_true',
    'default': False,
    'help': 'Do not remove temporary files. This option may leave behind many unwanted files including all '
            'intermediate local assembly files.'
}

args_dict['tempdir'] = {
    'default': None,
    'help': 'Temporary directory.'
}

args_dict['verbose'] = {
    'action': 'store_true',
    'help': 'Print extra runtime information.'
}

args_dict['wait_time'] = {
    'type': int,
    'default': 60,
    'help': 'Number of seconds to wait for files after a jobs finishes before giving up. Set to a high value for'
            'distributed storage with high latency.'
}

args_dict['cluster_params'] = {
    'default': ' -V -cwd -j y -o ./{log} '
               '-pe serial {{cluster.cpu}} '
               '-l mfree={{cluster.mem}} '
               '-l h_rt={{cluster.rt}} '
               '{{cluster.params}} '
               '-l gpfsstate=0 '
               '-w n -S /bin/bash',
    'help': 'Cluster scheduling parameters with place-holders as {{cluster.XXX}} for parameters in the cluster '
            'configuration file (--cluster-config) and {log} for the log directory where standard output from cluster '
            'jobs is written.'
}


#
# Mulitple Component Options
#

# mapping_quality
args_dict['mapping_quality'] = {
    'type': int,
    'default': 30,
    'help': 'Minimum mapping quality of raw reads. Used by "detect" to filter reads while finding gaps and hardstops. '
            'Used by "assemble" to filter reads with low mapping quality before the assembly step.'
}


#
# Reference
#

# reference
args_dict['reference'] = {
    'default': None,
    'help': 'FASTA file of reference to index.',
}

args_dict['no_link_index'] = {
    'dest': 'link_index',
    'action': 'store_false',
    'default': True,
    'help': 'If reference index files exist (.fai, .sa, or .ctab), then do not link them. This forces SMRTSV to build'
            'it\'s own set of indices',
}


#
# Align
#

# alignment_parameters
args_dict['alignment_parameters'] = {
    'default':
        '--bestn 2 '
        '--maxAnchorsPerPosition 100 '
        '--advanceExactMatches 10 '
        '--affineAlign '
        '--affineOpen 100 '
        '--affineExtend 0 '
        '--insertion 5 '
        '--deletion 5 '
        '--extend '
        '--maxExtendDropoff 50',
    'help': 'BLASR parameters for raw read alignments.'
}

# batches
args_dict['batches'] = {
    'type': int,
    'default': 20,
    'help': 'number of batches to split input reads into such that there will be one BAM output file per batch'
}

# reads
args_dict['reads'] = {
    'default': '',
    'help': 'Text file with each line containing an absolute path to an input file of read data. Read data must be'
            'from PacBio sequencing technology and be in BAM (.bam) or BAX (.bax.h5) format.'
}

# threads
args_dict['threads'] = {
    'help': 'Number of threads to use for each alignment job.',
    'type': int,
    'default': 1
}


#
# Detect
#

# assembly_window_size
args_dict['assembly_window_size'] = {
    'type': int,
    'default': 60000,
    'help': 'size of reference window for local assemblies.'

}

# assembly_window_slide
args_dict['assembly_window_slide'] = {
    'type': int,
    'default': 20000,
    'help': 'size of reference window slide for local assemblies.',
}

args_dict['candidate_group_size'] = {
    'type': int,
    'default': int(1e6),
    'help': 'Candidate regions are grouped into batches of this size. When local assemblies are performed, '
            'reads are first extracted over the window and stored on the compute node. Then reads for each '
            'local assembly are pulled from the cached reads on the compute node. If jobs are not distributed,'
            'the tuning of this parameter has little effect.'
}

# exclude
args_dict['exclude'] = {
    'default': None,
    'help': 'BED file of regions to exclude from local assembly (e.g., heterochromatic sequences, etc.).'
}

# max_candidate_length
args_dict['max_candidate_length'] = {
    'type': int,
    'default': 60000,
    'help': 'Maximum length allowed for an SV candidate region.'
}

# max_coverage
args_dict['max_coverage'] = {
    'type': int,
    'default': 100,
    'help': 'Maximum number of total reads allowed to flag a region as an SV candidate.'
}

# max_support
args_dict['max_support'] = {
    'type': int,
    'default': 100,
    'help': 'Maximum number of supporting reads allowed to flag a region as an SV candidate.'
}

# min_coverage
args_dict['min_coverage'] = {
    'type': int,
    'default': 5,
    'help': 'Minimum number of total reads required to flag a region as an SV candidate.'
}

# min_hardstop_support
args_dict['min_hardstop_support'] = {
    'type': int,
    'default': 11,
    'help': 'Minimum number of reads with hardstops required to flag a region as an SV candidate.'
}

# min_length
args_dict['min_length'] = {
    'type': int,
    'default': 50,
    'help': 'Minimum length required for SV candidates.'
}

# min_support
args_dict['min_support'] = {
    'type': int,
    'default': 5,
    'help': 'Minimum number of supporting reads required to flag a region as an SV candidate.'
}


#
# Local Assembly
#

# asm_alignment_parameters
args_dict['asm_alignment_parameters'] = {
    'default':
        '--affineAlign '
        '--affineOpen 8 '
        '--affineExtend 0 '
        '--bestn 1 '
        '--maxMatch 30 '
        '--sdpTupleSize 13',
    'help': 'BLASR parameters to use to align local assemblies.'
}

# asm_cpu
args_dict['asm_cpu'] = {
    'type': int,
    'default': 4,
    'help': 'Number of CPUs to use for assembly steps.'
}

# asm_mem
args_dict['asm_mem'] = {
    'default': '1G',
    'help':
        'Multiply this amount of memory by the number of cores for the amount of memory allocated to assembly steps.'
        'If multiple simultaneous assemblies are run, then this is multiplied again by that factor (see --asm-parallel).'
}

# asm_polish
args_dict['asm_polish'] = {
    'default': 'arrow',
    'help':
        'Assembly polishing method (arrow|quiver). "arrow" should work on all PacBio data, but "quiver" will only '
        'work on RS II input.'
}

# asm_group_rt
args_dict['asm_group_rt'] = {
    'default': '72:00:00',
    'help':
        'Set maximum runtime for an assembly group. Assemblies are grouped by region, and multiple assemblies are done '
        'in one grouped job. This is the maximum runtime for the whole group.'
}

args_dict['asm_parallel'] = {
    'type': int,
    'default': 1,
    'help':
        'Number of simultaneous assemblies to run. The actual thread count will be this times --asm-cpu'
}

# asm_group_rt
args_dict['asm_rt'] = {
    'default': '30m',
    'help':
        'Set maximum runtime for an assembly region. This should be a valid argument for the Linux "timeout" command.'
}


#
# Variant caller
#

# variants
args_dict['variants'] = {
    'default': 'variants.vcf.gz',
    'help': 'VCF of variants called by local assembly alignments.',
    'nargs': '?'
}

# sample
args_dict['sample'] = {
    'default': 'UnnamedSample',
    'help': 'Sample name to use in final variant calls'
}

# species
args_dict['species'] = {
    'default': 'human',
    'help': 'Common or scientific species name to pass to RepeatMasker.'
}

# rmsk
args_dict['rmsk'] = {
    'dest': 'rmsk',
    'action': 'store_true',
    'default': False,
    'help': 'Run RepeatMasker on SVs. This option was developed using RepeatMasker 3.3.0 with the WU-BLAST engine. '
            'With other versions, it may not run smoothly or it may cause failures in later steps.'
}


#
# Run
#

# runjobs
args_dict['runjobs'] = {
    'help':
        'A comma-separated list of jobs for each step: align, detect, assemble, and call (in that order). A missing '
        'number uses the value set by --jobs (or 1 if --jobs was not set).',
    'default': ''
}


#
# Genotyper
#

# genotyper_config
args_dict['genotyper_config'] = {
    'help':
        'JSON configuration file with SV reference paths, samples to genotype as BAMs, '
        'and their corresponding references.'
}

args_dict['gt_mapq'] = {
    'type': int,
    'default': 20,
    'help': 'Minimum mapping quality of short reads against the reference and contigs.'
}

# genotyped_variants
args_dict['genotyped_variants'] = {
    'help': 'VCF of SMRT SV variant genotypes for the given sample-level BAMs.'
}

# CPU cores for BWA mapping jobs
args_dict['gt_map_cpu'] = {
    'type': int,
    'default': 8,
    'help': 'Memory per CPU core to allocate for BWA mapping jobs.'
}

# Memory per CPU core for BWA mapping jobs
args_dict['gt_map_mem'] = {
    'default': '2.5G',
    'help': 'Memory per CPU core to allocate for BWA mapping jobs.'
}

args_dict['gt_map_disk'] = {
    'default': '15G',
    'help': 'Temp space per CPU Core to allocate for BWA mapping jobs.'
}

args_dict['gt_map_time'] = {
    'default': '72:00:00',
    'help': 'Maximum runtime to allocate for BWA mapping jobs.'
}

# Keep temp files
args_dict['gt_keep_temp'] = {
    'action': 'store_true',
    'help': 'Do not remove temp directory after genotyping.'
}


#############
# Functions #
#############

def get_arg(key, args=None, default=None, default_none=False):
    """
    Get an argument from object `args` or the default value for an argument if it is not in `args`.

    :param key: Argument key (name).
    :param args: Argument object or `None` to always get the default argument.
    :param default: Default value if not in `args`. Uses hard-coded default if `None`.
    :param default_none: If `True` and there is no default argument, return `None` instead of throwing an error.

    :return: Argument value.

    Raises:
        KeyError: If `key` is not in `args` and does not have a default value.
    """

    # Get argument from args
    if args is not None and hasattr(args, key):
        return getattr(args, key)

    # Get explicit default value
    if default is not None:
        return default

    # Get hard-coded default value
    if key not in args_dict:
        raise KeyError('No record for argument with key {} in built-in argument dictionary'.format(key))

    if 'default' in args_dict[key]:
        return args_dict[key]['default']

    if 'action' in args_dict[key] and args_dict[key]['action'] == 'store_true':
        # 'action' entries have an implicit default of False
        return False

    # No value, no default
    if default_none:
        return None

    raise KeyError('No default value for argument with key {}'.format(key))
