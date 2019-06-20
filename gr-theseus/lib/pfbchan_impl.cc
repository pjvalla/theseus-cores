/* -*- c++ -*- */
/*
 * Copyright 2018 Ettus Research
 *
 * This is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 3, or (at your option)
 * any later version.
 *
 * This software is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this software; see the file COPYING.  If not, write to
 * the Free Software Foundation, Inc., 51 Franklin Street,
 * Boston, MA 02110-1301, USA.
 */

#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include "pfbchan_impl.h"
#include <gnuradio/io_signature.h>
#include <gnuradio/block.h>
#include <gnuradio/block_detail.h>

namespace gr {
  namespace theseus {

    pfbchan::sptr
    pfbchan::make(
        const gr::ettus::device3::sptr &dev,
        const int block_select,
        const int device_select
    )
    {
        return gnuradio::get_initial_sptr(
            new pfbchan_impl(
                dev,
                block_select,
                device_select
            )
        );
    }

    /*
     * The private constructor
     */
    pfbchan_impl::pfbchan_impl(
        const gr::ettus::device3::sptr &dev,
        const int block_select,
        const int device_select
    )
      : gr::ettus::rfnoc_block("pfbchannelizer"),
        gr::ettus::rfnoc_block_impl(
            dev,
            gr::ettus::rfnoc_block_impl::make_block_id("pfbchannelizer",  block_select, device_select),
            ::uhd::stream_args_t("fc32", "sc16"),
            ::uhd::stream_args_t("fc32", "sc16"))
    {
        gr::block::set_min_noutput_items(256);
    }

    /*
     * Our virtual destructor.
     */
    pfbchan_impl::~pfbchan_impl()
    {
    }

    bool pfbchan_impl::start()
    {
      // Copy from rfnoc_block_impl
      // Need to override behavior so there's only one rx streamer for N outputs
      boost::recursive_mutex::scoped_lock lock(d_mutex);
      size_t ninputs  = detail()->ninputs();
      size_t noutputs = 1; // Hardcode noutputs to 1 (only 1 rx streamer)
      _rx.align = false; // Just call unaligned
      GR_LOG_DEBUG(d_debug_logger, str(boost::format("start(): ninputs == %d noutputs == %d") % ninputs % noutputs));

      if (ninputs == 0 && noutputs == 0) {
          return true;
      }

      // If the topology changed, we need to clear the old streamers
      if (_rx.streamers.size() != noutputs) {
        _rx.streamers.clear();
      }
      if (_tx.streamers.size() != ninputs) {
        _tx.streamers.clear();
      }

      //////////////////// TX ///////////////////////////////////////////////////////////////
      // Setup TX streamer.
      if (ninputs && _tx.streamers.empty()) {
        // Get a block control for the tx side:
        ::uhd::rfnoc::sink_block_ctrl_base::sptr tx_blk_ctrl =
            boost::dynamic_pointer_cast< ::uhd::rfnoc::sink_block_ctrl_base >(_blk_ctrl);
        if (!tx_blk_ctrl) {
          GR_LOG_FATAL(d_logger, str(boost::format("Not a sink_block_ctrl_base: %s") % _blk_ctrl->unique_id()));
          return false;
        }
        if (_tx.align) { // Aligned streamers:
          GR_LOG_DEBUG(d_debug_logger, str(boost::format("Creating one aligned tx streamer for %d inputs.") % ninputs));
          GR_LOG_DEBUG(d_debug_logger,
              str(boost::format("cpu: %s  otw: %s  args: %s channels.size: %d ") % _tx.stream_args.cpu_format % _tx.stream_args.otw_format % _tx.stream_args.args.to_string() % _tx.stream_args.channels.size()));
          assert(ninputs == _tx.stream_args.channels.size());
          ::uhd::tx_streamer::sptr tx_stream = _dev->get_tx_stream(_tx.stream_args);
          if (tx_stream) {
            _tx.streamers.push_back(tx_stream);
          } else {
            GR_LOG_FATAL(d_logger, str(boost::format("Can't create tx streamer(s) to: %s") % _blk_ctrl->get_block_id().get()));
            return false;
          }
        } else { // Unaligned streamers:
          for (size_t i = 0; i < size_t(ninputs); i++) {
            _tx.stream_args.channels = std::vector<size_t>(1, i);
            _tx.stream_args.args["block_port"] = str(boost::format("%d") % i);
            GR_LOG_DEBUG(d_debug_logger, str(boost::format("creating tx streamer with: %s") % _tx.stream_args.args.to_string()));
            ::uhd::tx_streamer::sptr tx_stream = _dev->get_tx_stream(_tx.stream_args);
            if (tx_stream) {
              _tx.streamers.push_back(tx_stream);
            }
          }
          if (_tx.streamers.size() != size_t(ninputs)) {
            GR_LOG_FATAL(d_logger, str(boost::format("Can't create tx streamer(s) to: %s") % _blk_ctrl->get_block_id().get()));
            return false;
          }
        }
      }

      _tx.metadata.start_of_burst = false;
      _tx.metadata.end_of_burst = false;
      _tx.metadata.has_time_spec = false;

      // Wait for all RFNoC streamers to have set up their tx streamers
      _tx_barrier.wait();

      //////////////////// RX ///////////////////////////////////////////////////////////////
      // Setup RX streamer
      if (noutputs && _rx.streamers.empty()) {
        // Get a block control for the rx side:
        ::uhd::rfnoc::source_block_ctrl_base::sptr rx_blk_ctrl =
            boost::dynamic_pointer_cast< ::uhd::rfnoc::source_block_ctrl_base >(_blk_ctrl);
        if (!rx_blk_ctrl) {
          GR_LOG_FATAL(d_logger, str(boost::format("Not a source_block_ctrl_base: %s") % _blk_ctrl->unique_id()));
          return false;
        }

        // Pay no attention to aligned/unaligned. Just make one streamer.
        _rx.stream_args.channels = std::vector<size_t>(1, 0) ;
        _rx.stream_args.args["block_port"] = str(boost::format("%d") % 0);
        GR_LOG_DEBUG(d_debug_logger, str(boost::format("creating rx streamer with: %s") % _rx.stream_args.args.to_string()));
        ::uhd::rx_streamer::sptr rx_stream = _dev->get_rx_stream(_rx.stream_args);
        if (rx_stream) {
          _rx.streamers.push_back(rx_stream);
        }
        if (_rx.streamers.size() != size_t(noutputs)) {
          GR_LOG_FATAL(d_logger, str(boost::format("Can't create rx streamer(s) to: %s") % _blk_ctrl->get_block_id().get()));
          return false;
        }
      }

      // Wait for all RFNoC streamers to have set up their rx streamers
      _rx_barrier.wait();

      // Start the streamers
      if (!_rx.streamers.empty()) {
        ::uhd::stream_cmd_t stream_cmd(::uhd::stream_cmd_t::STREAM_MODE_START_CONTINUOUS);
        if (_start_time_set) {
            stream_cmd.stream_now = false;
            stream_cmd.time_spec = _start_time;
            _start_time_set = false;
        } else {
            stream_cmd.stream_now = true;
        }
        for (size_t i = 0; i < _rx.streamers.size(); i++) {
          _rx.streamers[i]->issue_stream_cmd(stream_cmd);
        }
      }

      return true;
    }

    /*********************************************************************
     * Streaming
     *********************************************************************/
    void pfbchan_impl::work_rx_u(
        int noutput_items,
        gr_vector_void_star &output_items
    ) {
      // Temporarily channel copy from rfnoc_block_impl
      // TODO: Implement the channel deinterleaving output

      assert(_rx.streamers.size() == 1);

      // In every loop iteration, this will point to the relevant buffer
      gr_vector_void_star buff_ptr(1);

      for (size_t i = 0; i < _rx.streamers.size(); i++) {
        buff_ptr[0] = output_items[i];
        //size_t num_vectors_to_recv = std::min(_rx.streamers[i]->get_max_num_samps() / _rx.vlen, size_t(noutput_items));
        size_t num_vectors_to_recv = noutput_items;
        size_t num_samps = _rx.streamers[i]->recv(
            buff_ptr,
            num_vectors_to_recv * _rx.vlen,
            _rx.metadata, 0.1, true
        );

        switch(_rx.metadata.error_code) {
          case ::uhd::rx_metadata_t::ERROR_CODE_NONE:
            break;

          case ::uhd::rx_metadata_t::ERROR_CODE_TIMEOUT:
            //its ok to timeout, perhaps the user is doing finite streaming
            std::cout << "timeout on chan " << i << std::endl;
            break;

          case ::uhd::rx_metadata_t::ERROR_CODE_OVERFLOW:
            // Not much we can do about overruns here
            std::cout << "overrun on chan " << i << std::endl;
            break;

          default:
            std::cout << boost::format("RFNoC Streamer block received error %s (Code: 0x%x)")
              % _rx.metadata.strerror() % _rx.metadata.error_code << std::endl;
        }

        if (_rx.metadata.end_of_burst) {
          for (size_t i = 0; i < output_items.size(); i++) {
            add_item_tag(
                i,
                nitems_written(i) + (num_samps / _rx.vlen) - 1,
                EOB_KEY, pmt::PMT_T
            );
          }
        }

        produce(i, num_samps / _rx.vlen);
      } /* end for (chans) */
    }

  } /* namespace theseus */
} /* namespace gr */
