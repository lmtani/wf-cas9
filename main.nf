#!/usr/bin/env nextflow

// Developer notes
// 
// This template workflow provides a basic structure to copy in order
// to create a new workflow. Current recommended pratices are:
//     i) create a simple command-line interface.
//    ii) include an abstract workflow scope named "pipeline" to be used
//        in a module fashion.
//   iii) a second concreate, but anonymous, workflow scope to be used
//        as an entry point when using this workflow in isolation.

import groovy.json.JsonBuilder
nextflow.enable.dsl = 2

include { fastq_ingress } from './lib/fastqingress'
include { start_ping; end_ping } from './lib/ping'


process summariseReads {
    // concatenate fastq and fastq.gz in a dir

   label "cas9"
    cpus 1
    input:
        tuple path(directory), val(sample_id), val(type)
    output:
        tuple val(sample_id), path("${sample_id}.stats"), emit: stats
        tuple val(sample_id), path("${sample_id}.fastq"), emit: reads

    shell:
    """
    fastcat -s ${sample_id} -r ${sample_id}.stats -x ${directory} > ${sample_id}.fastq
    """
}


process getVersions {
   label "cas9"
    cpus 1
    output:
        path "versions.txt"
    script:
    """
    python -c "import pysam; print(f'pysam,{pysam.__version__}')" >> versions.txt
    fastcat --version | sed 's/^/fastcat,/' >> versions.txt
    """
}


process getParams {
   label "cas9"
    cpus 1
    output:
        path "params.json"
    script:
        def paramsJSON = new JsonBuilder(params).toPrettyString()
    """
    # Output nextflow params object to JSON
    echo '$paramsJSON' > params.json
    """
}

process make_tiles {
    input:
        path chrom_sizes
    output:
        path 'tiles.bed', emit: tiles
    script:
    """
    bedtools makewindows -g $chrom_sizes -w 100 -i 'srcwinnum' | gzip > tiles.bed
    """
}

process build_index{
    /*
    Build minimap index from reference genome
    */
    label "cas9"
    cpus params.threads

    input:
        file reference
    output:
        path "genome_index.mmi", emit: index
        path("chrom.sizes"), emit: chrom_sizes
    script:
    """
        minimap2 -t $params.threads -x map-ont -d genome_index.mmi $reference
        samtools faidx $reference
        cut -f 1,2 ${reference}.fai >> chrom.sizes
    """
}

process align_reads {
    /*
    TODO: The number of off-target is quite a lot higher than in the tutorial
    Tutorial uses mini_align rather than minimap2 directly.

    mini_align \
    -r "$reference_genome" -i "$input_file" \
    -p "$output_folder/alignments" \
    -t 4 -m
    */
    label "cas9"
    input:
        path index
        path reference
        tuple val(sample_id), file(fastq_reads)
    output:
        tuple val(sample_id), path("${sample_id}.sam"), emit: sam
        tuple val(sample_id), path("${sample_id}_fastq_pass.bed"), emit: bed
    script:
    """
    minimap2 -t $params.threads -m 4 -ax map-ont $index $fastq_reads > ${sample_id}.sam
    bedtools bamtobed -i ${sample_id}.sam | bedtools sort > ${sample_id}_fastq_pass.bed
    """
}

process target_coverage {
    /* Call the python processing script and get back CSVs that will be used in the report
    emits
        target_coverage: tiled csv for creating plots
        coverage summary: csv for table with stats for all targets aggregated
        target_summary: csv with summary info for each plot

    # NOTE
    use \W\+\W as strand may move columns in future versions

     */
    label "cas9"
    input:
        path targets
        path tiles
        path chrom_sizes
        tuple val(sample_id),
              path(aln)
    output:
        tuple val(sample_id), path('*_target_cov.bed'), emit: target_coverage

    script:
    """
    # Bed file for mapping tile to target
    bedtools intersect -a $tiles -b $targets -wb > tiles_int_targets.bed

    # Get alignment coverage at tiles per strand
    cat $aln | grep "\\+\$" | bedtools coverage -a tiles_int_targets.bed -b - | \
    cut -f 1,2,3,4,8,9 > pos.bed

    cat $aln | grep "\\-\$" | bedtools coverage -a tiles_int_targets.bed -b - | \
    cut -f 4,9 > neg.bed

    # Cols ["chr", "start", "end", 'name_f', "target", "coverage_f", 'name_r', 'coverage_r']
    paste pos.bed neg.bed > ${sample_id}_target_cov.bed

    rm pos.bed neg.bed
    """
}

process target_summary {
    label "cas9"
    input:
        path targets
        path tiles
        path chrom_sizes
        tuple val(sample_id),
              path(aln)
    output:
        tuple val(sample_id), path('*_target_summary.bed'), emit: table
    script:
    """
    # chr, start, stop (target), target, overlaps, covered_bases, len(target), frac_covered
    bedtools coverage -a $targets -b $aln | bedtools sort > target_summary_temp.bed

    # Bed file for mapping tile to target
    bedtools intersect -a $tiles -b $targets -wb > tiles_int_targets.bed

    # Get alignment coverage at tiles per strand
    cat $aln | bedtools coverage -a tiles_int_targets.bed -b - > target_cov.bed
    bedtools groupby -i target_cov.bed -g 1 -c 9 -o median | cut -f 2  > median_coverage.bed

    # Map targets to aln
    cat $aln | bedtools intersect -a - -b $targets -wb > aln_tagets.bed

    # Strand bias
    cat aln_tagets.bed | grep '\\W+\\W' | bedtools coverage -a - -b $targets -wb | \
    bedtools sort | bedtools groupby -g 10 -c 1 -o count | cut -f 2  > pos.bed

    cat aln_tagets.bed | grep '\\W-\\W' | bedtools coverage -a - -b $targets -wb | \
     bedtools groupby -g 10 -c 1 -o count | cut -f 2 > neg.bed

    # Mean read len
    cat aln_tagets.bed | bedtools coverage -a - -b $targets -wb | bedtools groupby -g 10 -c 13 -o mean | cut -f2 >  mean_read_len.bed

    # Kbases of coverage
    cat aln_tagets.bed | bedtools coverage -a - -b $targets -wb | bedtools groupby -g 10, -c 12 -o sum | cut -f 2 > kbases.bed

    paste target_summary_temp.bed \
      mean_read_len.bed \
      kbases.bed \
      median_coverage.bed \
      pos.bed \
      neg.bed > ${sample_id}_target_summary.bed

    rm mean_read_len.bed kbases.bed median_coverage.bed pos.bed neg.bed
    """
}

process coverage_summary {
    label "cas9"
    input:
        path targets
        tuple val(sample_id),
              path(aln)
    output:
        tuple val(sample_id), path('*on_off_summ.csv'), emit: summary
        tuple val(sample_id), path('*on_off.bed'), emit: on_off
    script:
    """
    # For table with cols:  num_reads, num_bases, mean read_len
    bedtools intersect -a $aln -b $targets -wa -wb -v | cut -f 1-4  > off.bed
    bedtools intersect -a $aln -b $targets -wa -wb | cut -f 1-4,10  > on.bed

    numread_on=\$(cat on.bed | wc -l | tr -d ' ')
    numread_off=\$(cat off.bed | wc -l | tr -d ' ')

    cat on.bed off.bed > ${sample_id}_on_off.bed

    bases_on=\$(cat on.bed | bedtools merge -i - | awk -F'\t' 'BEGIN{SUM=0}{ SUM+=\$3-\$2 }END{print SUM}')
    bases_off=\$(cat off.bed | bedtools merge -i - | awk -F'\t' 'BEGIN{SUM=0}{ SUM+=\$3-\$2 }END{print SUM}')

    echo "\${numread_on}\t\${numread_off}\n\${bases_on}\t\${bases_off}" > ${sample_id}_on_off_summ.csv
    """
}

process background {
    label "cas9"
    input:
        path targets
        path tiles
        path chrom_sizes
        tuple val(sample_id),
              path(aln)
    output:
        tuple val(sample_id), path('*_tiles_background_cov.bed'), emit: table
        tuple val(sample_id), path('*off_target_hotspots.bed'), emit: hotspots
    script:
    """
    bedtools slop -i $targets -g $chrom_sizes -b 1000 | tee  targets_padded.bed | \
    # remove reads that overlap slopped targets
    bedtools intersect -v -a $aln -b - -wa | \
    bedtools coverage -a $tiles -b - > ${sample_id}_tiles_background_cov.bed

    # Get all contiguous regions of background alignments
    cat targets_padded.bed | bedtools intersect -a $aln -b - -v  | \
    bedtools merge -i - | bedtools coverage -a - -b $aln | \
    cut -f 1-4 > ${sample_id}_off_target_hotspots.bed
    """
}

process makeReport {
   label "cas9"
    input:
        path "versions/*"
        path "params.json"
        tuple val(sample_ids),
              path(seq_summaries),
              path(target_coverage),
              path(target_summary_table),
              path(background),
              path(off_target_hotspots),
              path(coverage_summary),
              path(on_off)
    output:
        path "wf-cas9-*.html", emit: report
    script:
        report_name = "wf-cas9-" + params.report_name + '.html'
    """
    report.py $report_name \
        --summaries $seq_summaries \
        --versions versions \
        --params params.json \
        --target_coverage $target_coverage \
        --target_summary $target_summary_table \
        --sample_ids $sample_ids \
        --background $background \
        --off_target_hotspots $off_target_hotspots \
        --coverage_summary $coverage_summary \
        --on_off $on_off
    """
}


// See https://github.com/nextflow-io/nextflow/issues/1636
// This is the only way to publish files from a workflow whilst
// decoupling the publish from the process steps.
process output {
    // publish inputs to output directory

    publishDir "${params.out_dir}/output/${sample_id}", mode: 'copy', pattern: "*"
    input:
        tuple val(sample_id), path(fname)
    output:
        path fname
    """
    echo "Writing output files"
    echo $fname
    """
}

process output_report {
    publishDir "${params.out_dir}", mode: 'copy', pattern: "*report.html"

    input:
        path fname
    output:
        path fname
    """
    echo "Copying report"
    """
}


// workflow module
workflow pipeline {
    take:
        reads
        ref_genome
        targets
    main:
        println(reads)
        build_index(ref_genome)
        summariseReads(reads)
//         sample_ids = summariseConcatReads.out.summary.flatMap({it -> it[0]})
        software_versions = getVersions()
        workflow_params = getParams()

        align_reads(
            build_index.out.index,
            ref_genome,
            summariseReads.out.reads)

        make_tiles(build_index.out.chrom_sizes)

        target_coverage(targets,
                make_tiles.out.tiles,
                build_index.out.chrom_sizes,
                align_reads.out.bed)

        target_summary(targets,
                       make_tiles.out.tiles,
                       build_index.out.chrom_sizes,
                       align_reads.out.bed)

        background(targets,
                    make_tiles.out.tiles,
                    build_index.out.chrom_sizes,
                    align_reads.out.bed)

        coverage_summary(targets,
                         align_reads.out.bed
                        .join(summariseReads.out.stats)
                        )

        report = makeReport(software_versions.collect(),
                        workflow_params,
                        summariseReads.out.stats
                        .join(target_coverage.out.target_coverage)
                        .join(target_summary.out.table)
                        .join(background.out.table)
                        .join(background.out.hotspots)
                        .join(coverage_summary.out.summary)
                        .join(coverage_summary.out.on_off)

//                         .join(background.out.table)
                  )
//                         .join(overlaps.out.target_coverage)
//                         .join(overlaps.out.target_summary)
//                         )
    emit:
        results = summariseReads.out.stats
        report
        // TODO: use something more useful as telemetry
        telemetry = workflow_params
}


// entrypoint workflow
WorkflowMain.initialise(workflow, params, log)
workflow {
    start_ping()

    ref_genome = file(params.ref_genome, type: "file")
    if (!ref_genome.exists()) {
        println("--ref_genome: File doesn't exist, check path.")
        exit 1
    }
    targets = file(params.targets, type: "file")
    if (!targets.exists()) {
        println("--targets: File doesn't exist, check path.")
        exit 1
    }

    samples = fastq_ingress(
        params.fastq, params.out_dir, params.sample, params.sample_sheet, params.sanitize_fastq)


    pipeline(samples, ref_genome, targets)
    output(pipeline.out.results)
    output_report(pipeline.out.report)
    end_ping(pipeline.out.telemetry)
}
