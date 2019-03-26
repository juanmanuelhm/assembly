"""Snakefile

Processes input fastq files to create consensus genomes and their associated summary statistics for the Seattle Flu Study.

To run:
    $ snakemake

Basic steps:
    1. Trim raw fastq's with Trimmomatic
    2. Map trimmed reads to each reference genomes in the reference panel using bowtie2 # This step may change with time
    3. Remove duplicate reads using Picard
    4. Call SNPs using varscan
    5. Use SNPs to generate full consensus genomes for each sample x reference virus combination
    6. Compute summary statistics for each sample x refernce virus combination

Adapted from Louise Moncla's illumina pipeline for influenza snp calling:
https://github.com/lmoncla/illumina_pipeline
"""
import sys, os
import glob
configfile: "config/config.json"

#### Helper functions and variable def'ns
def generate_sample_ids(cfg):
    """Return all the sample names (i.e. S04) as a list.
    """
    all_ids = set()
    for f in glob.glob("{}/*".format(cfg['fastq_directory'])):
        if f.endswith('.fastq.gz'):
            f = f.split('.')[0].split('/')[-1].split('_')[1]
            all_ids.add(f)
    return all_ids

def generate_all_files(sample, config):
    """For a given sample, determine all fastqs as a tuple of forward
    and reverse
    """
    r1 = glob.glob('{}/*{}*R1*'.format(config['fastq_directory'], sample))
    r2 = glob.glob('{}/*{}*R2*'.format(config['fastq_directory'], sample))
    return (r1, r2)

all_references = [ v for v in  config['reference_viruses'].keys() ]
all_ids = generate_sample_ids(config)
mapped = {id: generate_all_files(id, config) for id in all_ids}

#### Main pipeline
rule all:
    input:
        consensus_genome = expand("consensus_genomes/{reference}/{sample}.consensus.fasta",
               sample=all_ids,
               reference=all_references),
        # pre_fastqc = expand("summary/pre_trim_fastqc/{sample}_fastqc.html",
        #        sample=all_sample_filenames),
        # post_fastqc = expand("summary/post_trim_fastqc/{sample}.trimmed_{tr}_fastqc.{ext}",
        #        sample=sample_filenames,
        #        tr=["1P", "1U", "2P", "2U"],
        #        ext=["zip", "html"]),
        # bamstats = expand("summary/bamstats/{reference}/{sample}.coverage_stats.txt",
        #        sample=all_ids,
        #        reference=all_references)

rule index_reference_genome:
    input:
        raw_reference = "references/{reference}.fasta"
    output:
        indexed_reference = "references/{reference}.1.bt2"
    shell:
        """
        bowtie2-build {input.raw_reference} references/{wildcards.reference}
        """



rule merge_lanes:
    input:
        all_r1 = lambda wildcards: mapped[wildcards.sample][0],
        all_r2 = lambda wildcards: mapped[wildcards.sample][1]
    output:
        merged_r1 = "process/merged/{sample}_R1.fastq.gz",
        merged_r2 = "process/merged/{sample}_R2.fastq.gz"
    shell:
        """
        cat {input.all_r1} >> {output.merged_r1}
        cat {input.all_r2} >> {output.merged_r2}
        """

rule pre_trim_fastqc:
    input:
        fastq = "%s/{sample}.fastq.gz"%(config["fastq_directory"])
    output:
        qc = "summary/pre_trim_fastqc/{sample}_fastqc.html",
        zip = "summary/pre_trim_fastqc/{sample}_fastqc.zip"
    shell:
        """
        fastqc {input.fastq} -o summary/pre_trim_fastqc
        """

rule trim_fastqs:
    input:
        fastq_f = "process/merged/{sample}_R1.fastq.gz",
        fastq_r = "process/merged/{sample}_R2.fastq.gz"
    output:
        trimmed_fastq_1p = "process/trimmed/{sample}.trimmed_1P.fastq",
        trimmed_fastq_2p = "process/trimmed/{sample}.trimmed_2P.fastq",
        trimmed_fastq_1u = "process/trimmed/{sample}.trimmed_1U.fastq",
        trimmed_fastq_2u = "process/trimmed/{sample}.trimmed_2U.fastq"
    params:
        paired_end = config["params"]["trimmomatic"]["paired_end"],
        adapters = config["params"]["trimmomatic"]["adapters"],
        illumina_clip = config["params"]["trimmomatic"]["illumina_clip"],
        window_size = config["params"]["trimmomatic"]["window_size"],
        trim_qscore = config["params"]["trimmomatic"]["trim_qscore"],
        minimum_length = config["params"]["trimmomatic"]["minimum_length"]
    shell:
        """
        trimmomatic \
            {params.paired_end} \
            -phred33 \
            {input.fastq_f} {input.fastq_r} \
            -baseout process/trimmed/{wildcards.sample}.trimmed.fastq \
            ILLUMINACLIP:{params.adapters}:{params.illumina_clip} \
            SLIDINGWINDOW:{params.window_size}:{params.trim_qscore} \
            MINLEN:{params.minimum_length}
        """

rule post_trim_fastqc:
    input:
        p1 = rules.trim_fastqs.output.trimmed_fastq_1p,
        p2 = rules.trim_fastqs.output.trimmed_fastq_2p,
        u1 = rules.trim_fastqs.output.trimmed_fastq_1u,
        u2 = rules.trim_fastqs.output.trimmed_fastq_2u
    output:
        qc_1p_html = "summary/post_trim_fastqc/{sample}.trimmed_1P_fastqc.html",
        qc_2p_html = "summary/post_trim_fastqc/{sample}.trimmed_2P_fastqc.html",
        qc_1u_html = "summary/post_trim_fastqc/{sample}.trimmed_1U_fastqc.html",
        qc_2u_html = "summary/post_trim_fastqc/{sample}.trimmed_2U_fastqc.html",
        qc_1p_zip = "summary/post_trim_fastqc/{sample}.trimmed_1P_fastqc.zip",
        qc_2p_zip = "summary/post_trim_fastqc/{sample}.trimmed_2P_fastqc.zip",
        qc_1u_zip = "summary/post_trim_fastqc/{sample}.trimmed_1U_fastqc.zip",
        qc_2u_zip = "summary/post_trim_fastqc/{sample}.trimmed_2U_fastqc.zip"
    shell:
        """
        fastqc {input.p1} -o summary/post_trim_fastqc
        fastqc {input.p2} -o summary/post_trim_fastqc
        fastqc {input.u1} -o summary/post_trim_fastqc
        fastqc {input.u2} -o summary/post_trim_fastqc
        """

rule map:
    input:
        p1 = rules.trim_fastqs.output.trimmed_fastq_1p,
        p2 = rules.trim_fastqs.output.trimmed_fastq_2p,
        u1 = rules.trim_fastqs.output.trimmed_fastq_1u,
        u2 = rules.trim_fastqs.output.trimmed_fastq_2u,
        ref_file = rules.index_reference_genome.output.indexed_reference
    output:
        mapped_sam_file = "process/mapped/{reference}/{sample}.sam",
        bt2_log = "summary/bowtie2/{reference}/{sample}.log"
    shell:
        """
        bowtie2 \
            -x references/{wildcards.reference} \
            -1 {input.p1} \
            -2 {input.p2} \
            -U {input.u1},{input.u2} \
            -S {output.mapped_sam_file} \
            --local 2> {output.bt2_log}
        """

rule sort:
    input:
        mapped_sam = rules.map.output.mapped_sam_file
    output:
        sorted_sam_file = "process/sorted/{reference}/{sample}.sorted.sam"
    shell:
        """
        samtools view \
            -bS {input.mapped_sam} | \
            samtools sort | \
            samtools view -h > {output.sorted_sam_file}
        """

rule bamstats:
    input:
        sorted_sam = rules.sort.output.sorted_sam_file
    output:
        bamstats_file = "summary/bamstats/{reference}/{sample}.coverage_stats.txt"
    shell:
        """
        bamstats -i {input.sorted_sam} > {output.bamstats_file}
        """

rule remove_duplicate_reads:
    input:
        sorted_sam = rules.sort.output.sorted_sam_file
    output:
        deduped = "process/deduped/{reference}/{sample}.nodups.sam"
    params:
        picard_params = "summary/file.params.txt"
    shell:
        """
        picard \
            MarkDuplicates \
            I={input.sorted_sam} \
            O={output.deduped} \
            REMOVE_DUPLICATES=true \
            M={params.picard_params}
        """

rule pileup:
    input:
        deduped_sam = rules.remove_duplicate_reads.output.deduped,
        reference = "references/{reference}.fasta"
    output:
        pileup = "process/mpileup/{reference}/{sample}.pileup"
    params:
        depth = config["params"]["mpileup"]["depth"]
    shell:
        """
        samtools mpileup \
            -d {params.depth} \
            {input.deduped_sam} > {output.pileup} \
            -f {input.reference}
        """

rule call_snps:
    input:
        pileup = rules.pileup.output.pileup
    output:
        vcf = "process/vcfs/{reference}/{sample}.vcf"
    params:
        min_cov = config["params"]["varscan"]["min_cov"],
        snp_qual_threshold = config["params"]["varscan"]["snp_qual_threshold"],
        snp_frequency = config["params"]["varscan"]["snp_frequency"],
    shell:
        """
        varscan mpileup2snp \
            {input.pileup} \
            --min-coverage {params.min_cov} \
            --min-avg-qual {params.snp_qual_threshold} \
            --min-var-freq {params.snp_frequency} \
            --strand-filter 1 \
            --output-vcf 1 > {output.vcf}
        """

rule zip_vcf:
    input:
        vcf = rules.call_snps.output.vcf
    output:
        bcf = "process/vcfs/{reference}/{sample}.vcf.gz"
    shell:
        """
        bgzip {input.vcf}
        """

rule index_bcf:
    input:
        bcf = rules.zip_vcf.output.bcf
    output:
        index = "process/vcfs/{reference}/{sample}.vcf.gz.csi"
    shell:
        """
        bcftools index {input}
        """

rule vcf_to_consensus:
    input:
        bcf = rules.zip_vcf.output.bcf,
        index = rules.index_bcf.output.index,
        ref = "references/{reference}.fasta"
    output:
        consensus_genome = "consensus_genomes/{reference}/{sample}.consensus.fasta"
    shell:
        """
        cat {input.ref} | \
            bcftools consensus {input.bcf} > \
            {output.consensus_genome}
        """
