/*
 *This is a nextflow workflow to do a  first quality check of metagenomic datasets.
 * Steps involve, fastqc, multiqc
 */

/* 
 * pipeline input parameters 
 */

log.info """\
         METAGENOMICS - N F   P I P E L I N E    
         ===================================
         
         input - reads                  : ${params.reads}
         files in read set              : ${params.setsize}
         output - directory             : ${params.outdir}
         temporary - directory          : ${workDir}
         Trimmomatic adapters           : ${params.adapters} 
         Trimmomatic adapters directory : ${params.adapter_dir}
         phix - directory               : ${params.phix_dir} 
         host - directory               : ${params.host_dir}
         """
         .stripIndent()

// Needed to run on the Abel cluster
preCmd = """
if [ -f /cluster/bin/jobsetup ];
then set +u; source /cluster/bin/jobsetup; set -u; fi
"""

// Creating the channels needed for the first analysis step
Channel 
    .fromFilePairs( params.reads, size:params.setsize, checkIfExists: true )
    .set { read_pairs_ch } 
 
/* running trimmomatic to remove adapters sequences
 * $task.cpus to specify cpus to use
 */ 

process run_trim {
    conda 'configuration_files/trimmomatic_env.yml'
    publishDir "${params.outdir}/05_fastq_trimmed", mode: "${params.savemode}"
    tag { pair_id }

    input:
    set pair_id, file(reads) from read_pairs_ch

    output:
    set pair_id, file("${pair_id}*.trimmed.fq.gz") into reads_trimmed_ch
    file "${pair_id}_trimmed.log"

    """
    ${preCmd}
    trimmomatic PE -threads $task.cpus -trimlog ${pair_id}_trimmed.log ${pair_id}*.gz \
    -baseout ${pair_id}_trimmed.fq.gz ILLUMINACLIP:${params.adapter_dir}/${params.adapters}:${params.illuminaClipOptions} \
    SLIDINGWINDOW:${params.slidingwindow} \
    LEADING:${params.leading} TRAILING:${params.trailing} \
    MINLEN:${params.minlen} &> ${pair_id}_run.log
    mv ${pair_id}_trimmed_1P.fq.gz ${pair_id}_R1.trimmed.fq.gz
    mv ${pair_id}_trimmed_2P.fq.gz ${pair_id}_R2.trimmed.fq.gz
    cat ${pair_id}_trimmed_1U.fq.gz ${pair_id}_trimmed_2U.fq.gz > ${pair_id}_S_concat_stripped_trimmed.fq.gz
    """
}

/*
 * remove low-complexity reads from datasets with bbduk
 */
process run_low_complex {
    conda 'configuration_files/bbmap_env.yml'
    publishDir "${params.outdir}/06_bbduk_highC", mode: "${params.savemode}"
    tag { pair_id }

    input:
    set pair_id, file(reads) from reads_trimmed_ch

    output:
    set pair_id, file("${pair_id}*.trimmed.highC.fq.gz") into reads_highC_ch
    file "${pair_id}_bbduk_output.log"

    """
    ${preCmd}
    bbduk.sh threads=$task.cpus entropy=0.7 entropywindow=50 entropyk=5 \
    in1=${pair_id}_R1.trimmed.fq.gz \
    in2=${pair_id}_R2.trimmed.fq.gz \
    outm=${pair_id}.lowC.reads.fq.gz \
    out1=${pair_id}_R1.trimmed.highC.fq.gz \
    out2=${pair_id}_R2.trimmed.highC.fq.gz \
    stats=stats.txt &> ${pair_id}_bbduk_output.log
    """
}

/*
 * remove reads matching to phiX with bbduk
 */
process remove_phiX {
    conda 'configuration_files/bbmap_env.yml'
    publishDir "${params.outdir}/07_bbduk_phix", mode: "${params.savemode}"
    tag { pair_id }

    input:
    set pair_id, file(reads) from reads_highC_ch

    output:
    set pair_id, file("${pair_id}*.trimmed.highC.phix.fq.gz") into reads_phix_ch
    file "${pair_id}_bbduk_output.log"

    """
    ${preCmd}
    bbduk.sh threads=$task.cpus ref=${params.phix_dir}/${params.phix_file} k=31 hdist=1 \
    in1=${pair_id}_R1.trimmed.highC.fq.gz \
    in2=${pair_id}_R2.trimmed.highC.fq.gz\
    outm=${pair_id}.phix.reads.fq.gz \
    out1=${pair_id}.R1.trimmed.highC.phix.fq.gz \
    out2=${pair_id}.R2.trimmed.highC.phix.fq.gz \
    stats=stats.txt &> ${pair_id}_bbduk_output.log
    """
}

/*
 * remove reads matching to human genome with bbmap
 */

process remove_host {
    conda 'configuration_files/bbmap_env.yml'
    publishDir "${params.outdir}/08_bbmap_host", mode: "${params.savemode}"
    tag { pair_id }

    input:
    set pair_id, file(reads) from reads_phix_ch

    output:
    set pair_id, file("${pair_id}.R*.clean.fq.gz") into  clean_data_ch1,  clean_data_ch2, clean_data_ch3, clean_data_ch4, clean_data_ch5
    file "${pair_id}.*.human.fq.gz"
    file "${pair_id}_bbmap_output.log"

    """
    ${preCmd}
    bbmap.sh -Xmx15g threads=6 \
    minid=0.95 maxindel=3 bwr=0.16 bw=12 \
    quickmatch fast minhits=2 \
    path=${params.host_dir} \
    in=${pair_id}.R1.trimmed.highC.phix.fq.gz\
    in2=${pair_id}.R2.trimmed.highC.phix.fq.gz \
    outu=${pair_id}.R1.clean.fq.gz \
    outu2=${pair_id}.R2.clean.fq.gz \
    outm=${pair_id}.R1.human.fq.gz \
    outm2=${pair_id}.R2.human.fq.gz \
    statsfile=${pair_id}.human_result.txt &> ${pair_id}_bbmap_output.log
    """
}

/* Run fastqc, Multi qc for quality control of the final cleaned datasets
*/

process fastqc {
    conda 'configuration_files/fastqc_env.yml'

    publishDir "${params.outdir}/01_fastqc", mode: "copy"
    
    tag "FASTQC on $sample_id"

    input:
    set sample_id, file(reads) from clean_data_ch1

    output:
    file("fastqc_${sample_id}_logs") into fastqc_clean_ch


    script:
    """
    ${preCmd}
    mkdir fastqc_${sample_id}_logs
    fastqc -o fastqc_${sample_id}_logs -f fastq -q ${reads}
    """  
}  
 
// running multiqc on the fastqc files from the channel: fastqc_clean_ch

process multiqc {
    conda 'configuration_files/multiqc_env.yml'
    publishDir "${params.outdir}/02_multiqc", mode: "${params.savemode}"
       
    input:
    file('*') from fastqc_clean_ch.collect()
    
    output:
    file('raw_data.multiqc_report.html')  
     
    script:
    """
    ${preCmd}
    multiqc . 
    mv multiqc_report.html raw_data.multiqc_report.html
    """
} 



/*
 * Calculate the sequence coverage of the clean metagenomes
 */
process run_coverage {
    conda 'configuration_files/nonpareil_env.yml'
    publishDir "${params.outdir}/09_nonpareil", mode: "${params.savemode}"
    tag { pair_id }

    input:
    set pair_id, file(reads) from clean_data_ch2

    output:
    file("${pair_id}*.npo") into r_plotting_ch
    file "${pair_id}*.npa"
    file "${pair_id}*.npc"
    file "${pair_id}*.npl"
    file "${pair_id}*.npo"
    
    

    """
    ${preCmd}
    gunzip -f *.fq.gz
    nonpareil -s *.R1.clean.fq -T kmer -f fastq -b ${pair_id}_R1 \
     -X ${params.query} -n ${params.subsample} -t $task.cpus
     sleep 10s
    """
}

/*
 * Create coverage calculations plots and combine into single html document
 */

 process plot_coverage {
    conda 'configuration_files/nonpareil_env.yml'
    publishDir "${params.outdir}/10_coverage_plots_clean_data", mode: "${params.savemode}"
    tag { "all samples" }

    input:
    file('*') from r_plotting_ch.collect()

    output:
    file "*.png"
    file "single_plots"   // folder with single file results

    """
    ${preCmd}
    mkdir single_plots
    Rscript $baseDir/Rscripts/process_npo_files.r
    """
}

/************************************************************
*********  Data analysis of clean data **********************
*************************************************************/

/* Calculate average genome size using microbecensus */

process Average_gsize {
    conda 'configuration_files/microbecensus_env.yml'
    publishDir "${params.outdir}/11_average_genome_size", mode: "${params.savemode}"
    tag { pair_id }

    input:
    set pair_id, file(reads) from clean_data_ch3

    output:
    file "*.txt"
    /* file "single_plots"   // folder with single file results */
    
    """
    ${preCmd}
    run_microbe_census.py -n 100000000 -t $task.cpus \
     ${pair_id}.R1.clean.fq.gz,${pair_id}.R2.clean.fq.gz \
     ${pair_id}.avgs_estimate.txt

    """
}

/*** TODO: add rscript to process average genome size results /


/* Calculate mash sketches of each clean dataset */

process mash_calculation {
    conda 'configuration_files/mash_env.yml'
    publishDir "${params.outdir}/12_mash_distances", mode: "${params.savemode}"
    tag { "all samples" }

    input:
    set pair_id, file(reads) from clean_data_ch4

    output:
    file("${pair_id}*.dist.msh") into mash_distance_ch
    
    """
    ${preCmd}
    gunzip -f ${pair_id}.R1.clean.fq.gz ${pair_id}.R2.clean.fq.gz
    
    cat ${pair_id}.R1.clean.fq ${pair_id}.R2.clean.fq > ${pair_id}.clean.fq
    
    rm -r ${pair_id}.R*.clean.fq  # clean up unwanted files

    mash sketch -b 10 -k 27 -s 50000 \
    -o ${pair_id}.dist.msh \
    -r ${pair_id}.clean.fq

    gzip ${pair_id}.clean.fq
    """
}

/* Calculate mash distances of all vs all datasets */

process mash_distance {
    conda 'configuration_files/mash_env.yml'
    publishDir "${params.outdir}/12_mash_distances", mode: "${params.savemode}"
    tag { "all samples" }

    input:
    file("*") from mash_distance_ch.collect()

    output:
    file("all_samples.dist.txt") into next_plot_ch
    
    """
    ${preCmd}
    mash dist *.dist.msh > all_samples.dist.txt
    """
}


/* Calculate hulk sketches of each clean dataset */

process hulk_calculation {
    conda 'configuration_files/hulk_env.yml'
    publishDir "${params.outdir}/12_hulk_distances", mode: "${params.savemode}"
    tag { "all samples" }

    input:
    set pair_id, file(reads) from clean_data_ch5

    output:
    file("${pair_id}.json") into hulk_distance_ch
    
    """
    ${preCmd}
    gunzip -f ${pair_id}.R*.clean.fq.gz
    cat ${pair_id}.R*.clean.fq > ${pair_id}.clean.fq

    hulk sketch -k 31 -f ${pair_id}.clean.fq -o ${pair_id} 
    
    """
}

/* Calculate hulk distances of all vs all datasets */

process hulk_distance {
    conda 'configuration_files/hulk_env.yml'
    publishDir "${params.outdir}/12_hulk_distances", mode: "${params.savemode}"
    tag { "all samples" }

    input:
    file("*") from hulk_distance_ch.collect()

    output:
    file("all_samples.Weighted_Jaccard.hulk-matrix.csv") into next_plot_ch2
    
    """
    ${preCmd}
    hulk smash -k 31 -m weightedjaccard -d ./ -o all_samples.Weighted_Jaccard

    """
}

/*** TODO: add rscript to process distance calculation and plot heatmap with clustering */